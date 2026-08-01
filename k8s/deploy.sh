#!/usr/bin/env bash
#
# Deploy dos 5 microsserviços do ToggleMaster no cluster EKS.
#
# Pré-requisitos (nesta ordem):
#   1. terraform apply em ../terraform/infra
#   2. aws eks update-kubeconfig
#   3. terraform apply em ../terraform/cluster-addons
#   4. imagens publicadas no ECR (use ./build-and-push.sh)
#
# Uso:
#   ./deploy.sh [TAG_DA_IMAGEM]     # default: v1
#
set -euo pipefail

IMAGE_TAG="${1:-v1}"
NAMESPACE="togglemaster"
INFRA_DIR="$(cd "$(dirname "$0")/../terraform/infra" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
die() { echo -e "\n\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

for cmd in terraform kubectl aws jq envsubst python3; do
  command -v "$cmd" >/dev/null || die "'$cmd' não encontrado. (envsubst vem do pacote gettext-base)"
done

# ---------------------------------------------------------------------------
# 1. Ler os outputs do Terraform
# ---------------------------------------------------------------------------
log "Lendo outputs do Terraform"
cd "$INFRA_DIR"

export AWS_REGION
AWS_REGION="$(terraform output -raw ecr_registry | cut -d. -f4)"
export ECR_REGISTRY="$(terraform output -raw ecr_registry)"
export REDIS_ENDPOINT="$(terraform output -raw redis_endpoint)"
export SQS_QUEUE_URL="$(terraform output -raw sqs_queue_url)"
export DYNAMODB_TABLE="$(terraform output -raw dynamodb_table_name)"
export IMAGE_TAG

RDS_ENDPOINTS="$(terraform output -json rds_endpoints)"
RDS_DBNAMES="$(terraform output -json rds_db_names)"
RDS_SECRETS="$(terraform output -json rds_master_user_secret_arns)"

echo "  Região:   $AWS_REGION"
echo "  ECR:      $ECR_REGISTRY"
echo "  Redis:    $REDIS_ENDPOINT"
echo "  Fila SQS: $SQS_QUEUE_URL"
echo "  Tag:      $IMAGE_TAG"

# Monta a DATABASE_URL de cada serviço lendo a senha do Secrets Manager.
# A senha nunca é digitada nem versionada: o RDS a gerou e guardou lá.
declare -A DB_URLS
for svc in auth flag targeting; do
  host="$(echo "$RDS_ENDPOINTS" | jq -r ".$svc" | cut -d: -f1)"
  dbname="$(echo "$RDS_DBNAMES" | jq -r ".$svc")"
  secret_arn="$(echo "$RDS_SECRETS" | jq -r ".$svc")"
  pass="$(aws secretsmanager get-secret-value --secret-id "$secret_arn" \
            --query SecretString --output text | jq -r .password)"

  # A senha gerada pelo RDS contém caracteres com significado sintático em
  # URLs (: @ ? * # / etc). Sem percent-encoding, "postgres://user:SENHA@host"
  # fica ambíguo e o driver falha com algo como
  # "invalid port ':XyZ(abc' after host".
  pass_enc="$(python3 -c \
    'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' \
    "$pass")"

  # sslmode=require: a conexão com o RDS vai por TLS.
  DB_URLS[$svc]="postgres://postgres:${pass_enc}@${host}:5432/${dbname}?sslmode=require"
done

# ---------------------------------------------------------------------------
# 2. Carregar o schema nos 3 bancos
# ---------------------------------------------------------------------------
# Necessário a CADA ciclo: o RDS é recriado vazio pelo terraform apply.
# Rodamos de dentro do cluster porque o RDS não é acessível pela internet.
log "Carregando schemas nos bancos (init.sql)"
for svc in auth flag targeting; do
  case $svc in
    auth)      sql_file="$REPO_ROOT/auth-service/db/init.sql" ;;
    flag)      sql_file="$REPO_ROOT/flag-service/db/init.sql" ;;
    targeting) sql_file="$REPO_ROOT/targeting-service/db/init.sql" ;;
  esac
  [[ -f "$sql_file" ]] || die "init.sql não encontrado: $sql_file"

  echo "  -> $svc"
  # Imagem do postgres vinda do ECR espelhado, não do Docker Hub.
  kubectl run "schema-$svc" --rm -i --restart=Never \
    --image="${ECR_REGISTRY}/mirror/library/postgres:15-alpine" \
    --env="PGURL=${DB_URLS[$svc]}" --command -- \
    sh -c 'psql "$PGURL" -v ON_ERROR_STOP=1 -f -' < "$sql_file" >/dev/null \
    || die "falha ao carregar o schema de $svc"
done

# ---------------------------------------------------------------------------
# 3. ConfigMap e Secrets
# ---------------------------------------------------------------------------
log "Aplicando ConfigMap"
envsubst < "$MANIFEST_DIR/01-configmap.yaml" | kubectl apply -f -

log "Criando Secrets"
# MASTER_KEY gerada aleatoriamente a cada deploy, em vez do valor de exemplo
# do docker-compose. Ela protege o endpoint /admin/keys do auth-service.
MASTER_KEY="$(openssl rand -hex 24)"

# --dry-run=client | kubectl apply torna a operação idempotente e evita
# escrever base64 na mão ou versionar o Secret em arquivo.
kubectl create secret generic auth-service-secret -n "$NAMESPACE" \
  --from-literal=DATABASE_URL="${DB_URLS[auth]}" \
  --from-literal=MASTER_KEY="$MASTER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic flag-service-secret -n "$NAMESPACE" \
  --from-literal=DATABASE_URL="${DB_URLS[flag]}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic targeting-service-secret -n "$NAMESPACE" \
  --from-literal=DATABASE_URL="${DB_URLS[targeting]}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 4. Fase 1: auth-service primeiro
# ---------------------------------------------------------------------------
# Por que duas fases: a tabela api_keys nasce VAZIA. O SERVICE_API_KEY que o
# evaluation-service usa para chamar flag/targeting não existe até alguém
# criá-lo via POST /admin/keys — e para isso o auth-service precisa estar no ar.
log "Fase 1: subindo auth-service"
envsubst < "$MANIFEST_DIR/02-auth-service.yaml" | kubectl apply -f -

# Se o Deployment já existia, o `apply` acima não muda nada (o manifesto é o
# mesmo) e o pod continua rodando com os valores ANTIGOS do Secret. Pior: se a
# tentativa anterior falhou, o Deployment está marcado como
# "progress deadline exceeded" e o rollout status abaixo falharia na hora.
# O restart cria um ReplicaSet novo, que relê os Secrets e zera esse estado.
kubectl rollout restart deploy/auth-service -n "$NAMESPACE"
kubectl rollout status deploy/auth-service -n "$NAMESPACE" --timeout=180s

# ---------------------------------------------------------------------------
# 5. Bootstrap da chave de serviço
# ---------------------------------------------------------------------------
log "Gerando SERVICE_API_KEY via /admin/keys"
kubectl port-forward -n "$NAMESPACE" svc/auth-service 18001:8001 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 4

SERVICE_API_KEY="$(curl -sf -X POST http://localhost:18001/admin/keys \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"evaluation-service"}' | jq -r .key)"

kill $PF_PID 2>/dev/null || true
trap - EXIT

[[ -n "$SERVICE_API_KEY" && "$SERVICE_API_KEY" != "null" ]] \
  || die "não foi possível criar a API key no auth-service"
echo "  Chave criada: ${SERVICE_API_KEY:0:12}..."

kubectl create secret generic evaluation-service-secret -n "$NAMESPACE" \
  --from-literal=SERVICE_API_KEY="$SERVICE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 6. Fase 2: o resto
# ---------------------------------------------------------------------------
log "Fase 2: subindo os demais serviços"
for f in 03-flag-service 04-targeting-service 05-evaluation-service 06-analytics-service 07-ingress; do
  envsubst < "$MANIFEST_DIR/$f.yaml" | kubectl apply -f -
done

log "Aplicando autoscaling (HPA + KEDA)"
kubectl apply -f "$MANIFEST_DIR/08-hpa-evaluation.yaml"
envsubst < "$MANIFEST_DIR/09-keda-analytics.yaml" | kubectl apply -f -

# Numa reexecução, os Deployments já existem e os pods carregam os valores
# ANTIGOS dos Secrets: envFrom resolve as variáveis na criação do pod e não
# recarrega quando o Secret muda. Sem este restart, corrigir um Secret e rodar
# o script de novo não teria efeito nenhum.
log "Reiniciando os pods para pegarem os Secrets desta execução"
kubectl rollout restart deployment -n "$NAMESPACE"

log "Aguardando os deployments"
for d in flag-service targeting-service evaluation-service; do
  kubectl rollout status "deploy/$d" -n "$NAMESPACE" --timeout=180s
done
# analytics-service não entra no rollout status: o KEDA pode tê-lo levado a 0
# réplicas se a fila estiver vazia, e aí o rollout nunca "completa".

# ---------------------------------------------------------------------------
# 7. Resultado
# ---------------------------------------------------------------------------
log "Estado final"
kubectl get pods -n "$NAMESPACE" -o wide
kubectl get hpa,scaledobject -n "$NAMESPACE"

echo ""
log "URL pública (o NLB leva 2-3 min para responder após a criação)"
NLB="$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -n "$NLB" ]]; then
  echo "  http://$NLB"
  echo ""
  echo "  Teste:  curl -i http://$NLB/flags"
else
  echo "  Ainda não provisionado. Rode:"
  echo "  kubectl get svc -n ingress-nginx ingress-nginx-controller"
fi

echo ""
echo "MASTER_KEY deste deploy (guarde se for criar mais chaves): $MASTER_KEY"
