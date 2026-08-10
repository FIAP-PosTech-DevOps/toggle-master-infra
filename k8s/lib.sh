#!/usr/bin/env bash
#
# Funções compartilhadas pelos scripts de deploy. Carregue com `source`.
#
# Não define `set -euo pipefail` de propósito: quem controla o modo de erro é
# o script que a carrega.

TM_NAMESPACE="togglemaster"
TM_K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TM_INFRA_DIR="$(cd "$TM_K8S_DIR/../terraform/infra" && pwd)"
TM_REPO_ROOT="$(cd "$TM_K8S_DIR/../.." && pwd)"

TM_SERVICES=(auth-service flag-service targeting-service evaluation-service analytics-service)

# --- Saída -------------------------------------------------------------------

tm_log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
tm_info() { echo "  $*"; }
tm_warn() { echo -e "\033[1;33mAVISO: $*\033[0m" >&2; }
tm_die()  { echo -e "\n\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

# --- Pré-requisitos ----------------------------------------------------------

tm_check_deps() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null \
      || tm_die "'$cmd' não encontrado. (envsubst vem do pacote gettext-base)"
  done
}

tm_check_cluster() {
  kubectl get namespace "$TM_NAMESPACE" >/dev/null 2>&1 \
    || tm_die "namespace '$TM_NAMESPACE' não existe. Aplique o módulo cluster-addons primeiro."
}

# --- Mapeamentos -------------------------------------------------------------

# Serviço -> arquivo de manifesto principal
tm_manifest_of() {
  case "$1" in
    auth-service)       echo "02-auth-service.yaml" ;;
    flag-service)       echo "03-flag-service.yaml" ;;
    targeting-service)  echo "04-targeting-service.yaml" ;;
    evaluation-service) echo "05-evaluation-service.yaml" ;;
    analytics-service)  echo "06-analytics-service.yaml" ;;
    *) return 1 ;;
  esac
}

# Serviço -> manifesto de autoscaling que o acompanha (vazio se não houver).
# HPA e ScaledObject viajam junto com seu serviço: fazem parte do contrato de
# escala dele, não da plataforma.
tm_autoscaler_of() {
  case "$1" in
    evaluation-service) echo "08-hpa-evaluation.yaml" ;;
    analytics-service)  echo "09-keda-analytics.yaml" ;;
    *) echo "" ;;
  esac
}

# Serviço -> chave usada nos outputs do Terraform para o banco (vazio se o
# serviço não tem banco relacional).
tm_db_key_of() {
  case "$1" in
    auth-service)      echo "auth" ;;
    flag-service)      echo "flag" ;;
    targeting-service) echo "targeting" ;;
    *) echo "" ;;
  esac
}

tm_is_valid_service() {
  local s
  for s in "${TM_SERVICES[@]}"; do
    [[ "$s" == "$1" ]] && return 0
  done
  return 1
}

# tm_sort_services <serviço...>
#
# Reordena a lista seguindo a ordem de dependência de TM_SERVICES. Importa
# quando o conjunto inclui o auth-service: ele precisa estar no ar antes do
# evaluation-service, que depende da SERVICE_API_KEY validada por ele.
# Também remove duplicatas.
tm_sort_services() {
  local canonical wanted out=()
  for canonical in "${TM_SERVICES[@]}"; do
    for wanted in "$@"; do
      if [[ "$canonical" == "$wanted" ]]; then
        out+=("$canonical")
        break
      fi
    done
  done
  printf '%s\n' "${out[@]}"
}

# --- Terraform ---------------------------------------------------------------

# Exporta as variáveis que o envsubst usa nos manifestos.
tm_load_outputs() {
  tm_log "Lendo outputs do Terraform"

  export ECR_REGISTRY REDIS_ENDPOINT SQS_QUEUE_URL DYNAMODB_TABLE AWS_REGION

  ECR_REGISTRY="$(terraform -chdir="$TM_INFRA_DIR" output -raw ecr_registry 2>/dev/null)" \
    || tm_die "não foi possível ler os outputs. O módulo infra foi aplicado?"
  AWS_REGION="$(echo "$ECR_REGISTRY" | cut -d. -f4)"
  REDIS_ENDPOINT="$(terraform -chdir="$TM_INFRA_DIR" output -raw redis_endpoint)"
  SQS_QUEUE_URL="$(terraform -chdir="$TM_INFRA_DIR" output -raw sqs_queue_url)"
  DYNAMODB_TABLE="$(terraform -chdir="$TM_INFRA_DIR" output -raw dynamodb_table_name)"

  tm_info "Região:   $AWS_REGION"
  tm_info "ECR:      $ECR_REGISTRY"
  tm_info "Redis:    $REDIS_ENDPOINT"
  tm_info "Fila SQS: $SQS_QUEUE_URL"
}

# tm_db_url <chave-do-banco>   ex: tm_db_url auth
#
# Monta a DATABASE_URL lendo a senha do Secrets Manager. A senha nunca é
# digitada nem versionada — o próprio RDS a gerou e guardou lá.
tm_db_url() {
  local key="$1" host dbname secret_arn pass pass_enc

  host="$(terraform -chdir="$TM_INFRA_DIR" output -json rds_endpoints | jq -r ".$key" | cut -d: -f1)"
  dbname="$(terraform -chdir="$TM_INFRA_DIR" output -json rds_db_names | jq -r ".$key")"
  secret_arn="$(terraform -chdir="$TM_INFRA_DIR" output -json rds_master_user_secret_arns | jq -r ".$key")"

  pass="$(aws secretsmanager get-secret-value --secret-id "$secret_arn" \
            --query SecretString --output text | jq -r .password)"

  # A senha gerada pelo RDS contém caracteres com significado sintático em
  # URLs (: @ ? * # /). Sem percent-encoding, "postgres://user:SENHA@host"
  # fica ambíguo e o driver falha com "invalid port ':XyZ(abc' after host".
  pass_enc="$(python3 -c \
    'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$pass")"

  # sslmode=require: a conexão com o RDS vai por TLS.
  echo "postgres://postgres:${pass_enc}@${host}:5432/${dbname}?sslmode=require"
}

# --- Recursos compartilhados -------------------------------------------------

tm_apply_configmap() {
  tm_log "Aplicando ConfigMap"
  envsubst < "$TM_K8S_DIR/01-configmap.yaml" | kubectl apply -f -
}

# tm_load_schema <serviço>
#
# Roda o init.sql de dentro do cluster, porque o RDS não é acessível pela
# internet. Idempotente: os scripts usam CREATE TABLE IF NOT EXISTS.
tm_load_schema() {
  local svc="$1" key sql_file
  key="$(tm_db_key_of "$svc")"
  [[ -n "$key" ]] || { tm_info "$svc não usa banco relacional, pulando schema"; return 0; }

  sql_file="$TM_REPO_ROOT/$svc/db/init.sql"
  [[ -f "$sql_file" ]] || tm_die "init.sql não encontrado: $sql_file"

  tm_info "carregando schema de $svc"
  kubectl run "schema-$key-$$" --rm -i --restart=Never \
    --image="${ECR_REGISTRY}/mirror/library/postgres:15-alpine" \
    --env="PGURL=$(tm_db_url "$key")" --command -- \
    sh -c 'psql "$PGURL" -v ON_ERROR_STOP=1 -f -' < "$sql_file" >/dev/null \
    || tm_die "falha ao carregar o schema de $svc"
}

# Devolve a MASTER_KEY atual. Se o Secret ainda não existe, gera uma nova.
#
# Preservar a chave existente é o que torna o redeploy isolado do auth-service
# seguro: gerar uma nova a cada deploy invalidaria a que você já tem anotada.
tm_master_key() {
  local existing
  existing="$(kubectl get secret auth-service-secret -n "$TM_NAMESPACE" \
    -o jsonpath='{.data.MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"

  if [[ -n "$existing" ]]; then
    echo "$existing"
  else
    openssl rand -hex 24
  fi
}

# tm_put_secret <nome> <chave=valor> [chave=valor ...]
#
# --dry-run=client | kubectl apply torna a operação idempotente e evita
# escrever base64 na mão ou versionar o Secret em arquivo.
tm_put_secret() {
  local name="$1"; shift
  local args=()
  local kv
  for kv in "$@"; do
    args+=(--from-literal="$kv")
  done
  kubectl create secret generic "$name" -n "$TM_NAMESPACE" \
    "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

tm_secret_exists() {
  kubectl get secret "$1" -n "$TM_NAMESPACE" >/dev/null 2>&1
}

# --- Rollout -----------------------------------------------------------------

# tm_rollout <serviço>
#
# O restart é obrigatório numa reexecução: `envFrom` resolve as variáveis na
# criação do pod e NÃO recarrega quando o Secret muda. Sem ele, corrigir um
# Secret e reaplicar o mesmo manifesto não teria efeito nenhum.
tm_rollout() {
  local svc="$1" timeout="${2:-180s}"

  kubectl rollout restart "deploy/$svc" -n "$TM_NAMESPACE"

  # analytics-service pode estar em 0 réplicas por causa do KEDA (scale-to-zero
  # com fila vazia). Nesse caso o rollout nunca "completa" e esperar trava.
  if [[ "$svc" == "analytics-service" ]]; then
    local replicas
    replicas="$(kubectl get deploy "$svc" -n "$TM_NAMESPACE" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    if [[ "${replicas:-0}" -eq 0 ]]; then
      tm_info "analytics-service está em 0 réplicas (KEDA scale-to-zero), não há rollout a aguardar"
      return 0
    fi
  fi

  kubectl rollout status "deploy/$svc" -n "$TM_NAMESPACE" --timeout="$timeout"
}

# --- Informação final --------------------------------------------------------

tm_print_nlb() {
  local nlb
  nlb="$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$nlb" ]]; then
    echo "  http://$nlb"
  else
    echo "  NLB ainda não provisionado (leva 2-3 min):"
    echo "    kubectl get svc -n ingress-nginx ingress-nginx-controller"
  fi
}
