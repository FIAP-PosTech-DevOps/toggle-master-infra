#!/usr/bin/env bash
#
# Bootstrap do OpenBao de um ambiente. Rode depois do `tf.sh cluster-addons
# <ambiente> apply`. É idempotente: rodar de novo não apaga nem troca nada que
# já exista (a não ser com --rotate-app-keys).
#
# O que faz:
#   1. Inicializa o OpenBao (só na primeira vez). Com auto-unseal por KMS, o
#      init gera "recovery keys" e o root token; os dois vão para o AWS
#      Secrets Manager (togglemaster/<ambiente>/openbao-init), nunca para
#      arquivo local nem para o Git.
#   2. Liga o KV v2 em secret/ e a autenticação Kubernetes.
#   3. Cria a policy de leitura e a role que o External Secrets usa.
#   4. Grava os segredos da aplicação:
#        secret/togglemaster/auth-service        DATABASE_URL, MASTER_KEY
#        secret/togglemaster/flag-service        DATABASE_URL
#        secret/togglemaster/targeting-service   DATABASE_URL
#        secret/togglemaster/evaluation-service  SERVICE_API_KEY
#
# A DATABASE_URL é montada com a senha que o próprio RDS gerou e guardou no
# Secrets Manager. Se a AWS rotacionar essa senha (padrão: a cada 7 dias),
# rode o script de novo para ressincronizar.
#
# Uso:
#   ./scripts/openbao-bootstrap.sh <develop|staging|production> [--rotate-app-keys]
#
#   --rotate-app-keys  gera MASTER_KEY e SERVICE_API_KEY novas
#
# Requer: aws, kubectl, jq, openssl, python3 e o terraform (via terraform/tf.sh).
#
set -euo pipefail

ENVIRONMENT="${1:-}"
ROTATE=false
[[ "${2:-}" == "--rotate-app-keys" ]] && ROTATE=true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/terraform/tf.sh"

NAMESPACE="openbao"
POD="openbao-0"
KV_PREFIX="secret/togglemaster"
POLICY_NAME="togglemaster-read"
ESO_ROLE="external-secrets"
ESO_NAMESPACE="external-secrets"
ESO_SERVICE_ACCOUNT="external-secrets"

log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
info() { echo "  $*"; }
die()  { echo -e "\n\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

case "$ENVIRONMENT" in
  develop|staging|production) ;;
  *) sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

for cmd in aws kubectl jq openssl python3; do
  command -v "$cmd" >/dev/null || die "'$cmd' não encontrado"
done

INIT_SECRET_ID="togglemaster/${ENVIRONMENT}/openbao-init"
CONTEXT="togglemaster-${ENVIRONMENT}"

# --- Outputs do Terraform ----------------------------------------------------
log "Lendo outputs do stack infra ($ENVIRONMENT)"
OUTPUTS="$("$TF" infra "$ENVIRONMENT" output -json)" \
  || die "não foi possível ler os outputs. O stack infra de $ENVIRONMENT foi aplicado?"

REGION="$(jq -r .aws_region.value <<<"$OUTPUTS")"
CLUSTER="$(jq -r .cluster_name.value <<<"$OUTPUTS")"
info "região:  $REGION"
info "cluster: $CLUSTER"

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CONTEXT" >/dev/null
K() { kubectl --context "$CONTEXT" "$@"; }

# --- Helpers para falar com o OpenBao sem expor o token ----------------------
# O token vai pela PRIMEIRA linha do stdin (nunca como argumento, que
# apareceria na lista de processos do pod); o resto do stdin, se houver,
# segue para o próprio comando `bao` (ex.: JSON de um kv put).
BAO_TOKEN_VALUE=""

bao() {
  printf '%s\n' "$BAO_TOKEN_VALUE" | K exec -i -n "$NAMESPACE" "$POD" -- \
    sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' bao "$@"
}

bao_stdin() {
  # uso: <conteúdo> | bao_stdin <args...>
  { printf '%s\n' "$BAO_TOKEN_VALUE"; cat; } | K exec -i -n "$NAMESPACE" "$POD" -- \
    sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' bao "$@"
}

bao_status() {
  # `bao status` sai com código 2 quando selado; o JSON vem mesmo assim.
  K exec -n "$NAMESPACE" "$POD" -- bao status -format=json 2>/dev/null || true
}

# --- 1. Inicialização --------------------------------------------------------
log "Aguardando o pod $POD"
K wait --for=jsonpath='{.status.phase}'=Running "pod/$POD" -n "$NAMESPACE" --timeout=300s >/dev/null \
  || die "o pod $POD não entrou em Running. Veja: kubectl --context $CONTEXT -n $NAMESPACE describe pod $POD"

STATUS="$(bao_status)"
[[ -n "$STATUS" ]] || die "não foi possível consultar o status do OpenBao"

if [[ "$(jq -r .initialized <<<"$STATUS")" != "true" ]]; then
  log "Inicializando o OpenBao (primeira vez)"
  INIT_JSON="$(K exec -n "$NAMESPACE" "$POD" -- \
    bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)"

  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$INIT_SECRET_ID" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" \
      --secret-id "$INIT_SECRET_ID" --secret-string "$INIT_JSON" >/dev/null
  else
    aws secretsmanager create-secret --region "$REGION" \
      --name "$INIT_SECRET_ID" \
      --description "Root token e recovery keys do OpenBao ($ENVIRONMENT)" \
      --secret-string "$INIT_JSON" >/dev/null
  fi
  unset INIT_JSON
  info "root token e recovery keys guardados em Secrets Manager: $INIT_SECRET_ID"
else
  info "já inicializado"
fi

log "Aguardando o auto-unseal (KMS)"
for _ in $(seq 1 30); do
  [[ "$(bao_status | jq -r .sealed)" == "false" ]] && break
  sleep 2
done
[[ "$(bao_status | jq -r .sealed)" == "false" ]] \
  || die "o OpenBao continua selado. Confira a role IRSA e a chave KMS: kubectl --context $CONTEXT -n $NAMESPACE logs $POD"
info "unsealed"

BAO_TOKEN_VALUE="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$INIT_SECRET_ID" --query SecretString --output text | jq -r .root_token)"
[[ -n "$BAO_TOKEN_VALUE" && "$BAO_TOKEN_VALUE" != "null" ]] \
  || die "root token não encontrado em $INIT_SECRET_ID"

# --- 2. Engines e autenticação ----------------------------------------------
log "Configurando KV v2 e autenticação Kubernetes"
if bao secrets list -format=json | jq -e 'has("secret/")' >/dev/null; then
  info "KV secret/ já habilitado"
else
  bao secrets enable -path=secret kv-v2 >/dev/null
  info "KV v2 habilitado em secret/"
fi

if bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  info "auth kubernetes já habilitado"
else
  bao auth enable kubernetes >/dev/null
  info "auth kubernetes habilitado"
fi

# Rodando dentro do pod, o OpenBao usa o token e a CA da própria
# ServiceAccount para validar os tokens que recebe (TokenReview).
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc" >/dev/null

# --- 3. Policy e role do External Secrets -----------------------------------
log "Policy $POLICY_NAME e role $ESO_ROLE"
bao_stdin policy write "$POLICY_NAME" - >/dev/null <<EOF
# Somente leitura dos segredos da aplicação. Nada de escrita, nada fora
# de ${KV_PREFIX}/.
path "secret/data/togglemaster/*" {
  capabilities = ["read"]
}
path "secret/metadata/togglemaster/*" {
  capabilities = ["read", "list"]
}
EOF

bao write "auth/kubernetes/role/$ESO_ROLE" \
  bound_service_account_names="$ESO_SERVICE_ACCOUNT" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  policies="$POLICY_NAME" \
  ttl=1h >/dev/null
info "SA $ESO_NAMESPACE/$ESO_SERVICE_ACCOUNT -> policy $POLICY_NAME"

# --- 4. Segredos da aplicação -----------------------------------------------
kv_field() {
  # Valor atual de um campo, ou vazio se o caminho/campo não existir.
  bao kv get -field="$2" "$KV_PREFIX/$1" 2>/dev/null || true
}

kv_put() {
  # uso: kv_put <serviço> <json>. O JSON vai por stdin, nunca por argumento.
  printf '%s' "$2" | bao_stdin kv put "$KV_PREFIX/$1" - >/dev/null
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

db_url() {
  local key="$1" host dbname secret_arn password
  host="$(jq -r ".rds_addresses.value.$key" <<<"$OUTPUTS")"
  dbname="$(jq -r ".rds_db_names.value.$key" <<<"$OUTPUTS")"
  secret_arn="$(jq -r ".rds_master_user_secret_arns.value.$key" <<<"$OUTPUTS")"
  password="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$secret_arn" \
    --query SecretString --output text | jq -r .password)"
  echo "postgres://postgres:$(urlencode "$password")@${host}:5432/${dbname}?sslmode=require"
}

log "Gravando segredos em $KV_PREFIX/"

MASTER_KEY="$(kv_field auth-service MASTER_KEY)"
if [[ -z "$MASTER_KEY" || "$ROTATE" == true ]]; then
  MASTER_KEY="$(openssl rand -hex 24)"
  info "MASTER_KEY gerada"
else
  info "MASTER_KEY preservada"
fi

# Mesmo formato do auth-service (key.go): "tm_key_" + 32 bytes em hex. O
# hash SHA-256 desta chave é gravado na tabela api_keys pelo Job de
# migração do auth-service (repo GitOps), então não é preciso chamar
# /admin/keys à mão como na Fase 2.
SERVICE_API_KEY="$(kv_field evaluation-service SERVICE_API_KEY)"
if [[ -z "$SERVICE_API_KEY" || "$ROTATE" == true ]]; then
  SERVICE_API_KEY="tm_key_$(openssl rand -hex 32)"
  info "SERVICE_API_KEY gerada"
else
  info "SERVICE_API_KEY preservada"
fi

kv_put auth-service "$(jq -n \
  --arg db "$(db_url auth)" --arg mk "$MASTER_KEY" \
  '{DATABASE_URL: $db, MASTER_KEY: $mk}')"
info "auth-service       DATABASE_URL, MASTER_KEY"

kv_put flag-service "$(jq -n --arg db "$(db_url flag)" '{DATABASE_URL: $db}')"
info "flag-service       DATABASE_URL"

kv_put targeting-service "$(jq -n --arg db "$(db_url targeting)" '{DATABASE_URL: $db}')"
info "targeting-service  DATABASE_URL"

kv_put evaluation-service "$(jq -n --arg k "$SERVICE_API_KEY" '{SERVICE_API_KEY: $k}')"
info "evaluation-service SERVICE_API_KEY"

unset MASTER_KEY SERVICE_API_KEY BAO_TOKEN_VALUE

log "Concluído"
cat <<EOF
  O External Secrets passa a sincronizar estes valores em até 1 minuto.
  Para forçar agora:
    kubectl --context $CONTEXT annotate externalsecret --all -A force-sync=\$(date +%s) --overwrite

  Interface do OpenBao:
    kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/openbao 8200:8200
    http://localhost:8200  (token: Secrets Manager -> $INIT_SECRET_ID -> root_token)
EOF
