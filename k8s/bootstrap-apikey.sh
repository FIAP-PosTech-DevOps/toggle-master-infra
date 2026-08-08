#!/usr/bin/env bash
#
# Cria uma SERVICE_API_KEY no auth-service e grava no Secret do
# evaluation-service.
#
# Existe separado do deploy porque a tabela api_keys nasce VAZIA: o init.sql
# cria a estrutura, não insere nenhuma chave. O evaluation-service precisa de
# uma chave válida para chamar o flag-service e o targeting-service, que a
# validam contra o auth-service — e ela só pode ser criada com o auth-service
# já no ar.
#
# Uso:
#   ./bootstrap-apikey.sh            # só cria se ainda não existir
#   ./bootstrap-apikey.sh --force    # gera uma nova, substituindo a atual
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

tm_check_deps kubectl jq curl openssl
tm_check_cluster

# ---------------------------------------------------------------------------
# Já existe?
# ---------------------------------------------------------------------------
if tm_secret_exists evaluation-service-secret && [[ "$FORCE" == false ]]; then
  tm_log "SERVICE_API_KEY já existe"
  tm_info "Use --force para gerar uma nova."
  exit 0
fi

# ---------------------------------------------------------------------------
# O auth-service precisa estar no ar
# ---------------------------------------------------------------------------
kubectl get deploy auth-service -n "$TM_NAMESPACE" >/dev/null 2>&1 \
  || tm_die "auth-service não está implantado. Rode: ./deploy-service.sh auth-service"

READY="$(kubectl get deploy auth-service -n "$TM_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[[ "${READY:-0}" -ge 1 ]] \
  || tm_die "auth-service não tem réplica pronta. Veja: kubectl get pods -n $TM_NAMESPACE -l app=auth-service"

MASTER_KEY="$(tm_master_key)"
[[ -n "$MASTER_KEY" ]] || tm_die "MASTER_KEY não encontrada no Secret auth-service-secret"

# ---------------------------------------------------------------------------
# Cria a chave via /admin/keys
# ---------------------------------------------------------------------------
# Usa port-forward em vez do NLB: funciona mesmo antes do Ingress existir, e
# não depende de o Load Balancer já ter sido provisionado.
tm_log "Criando SERVICE_API_KEY via /admin/keys"

kubectl port-forward -n "$TM_NAMESPACE" svc/auth-service 18001:8001 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 4

RESP="$(curl -sf -X POST http://localhost:18001/admin/keys \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"evaluation-service"}' || true)"

kill $PF_PID 2>/dev/null || true
trap - EXIT

SERVICE_API_KEY="$(echo "$RESP" | jq -r .key 2>/dev/null || true)"

if [[ -z "$SERVICE_API_KEY" || "$SERVICE_API_KEY" == "null" ]]; then
  echo "Resposta do auth-service: ${RESP:-<vazia>}" >&2
  tm_die "não foi possível criar a API key (MASTER_KEY inválida ou serviço indisponível)"
fi

tm_info "chave criada: ${SERVICE_API_KEY:0:12}…"

tm_put_secret evaluation-service-secret "SERVICE_API_KEY=$SERVICE_API_KEY"

# ---------------------------------------------------------------------------
# O evaluation-service precisa reler o Secret
# ---------------------------------------------------------------------------
if kubectl get deploy evaluation-service -n "$TM_NAMESPACE" >/dev/null 2>&1; then
  tm_log "Reiniciando o evaluation-service para carregar a nova chave"
  tm_rollout evaluation-service
else
  tm_info "evaluation-service ainda não implantado — a chave será usada quando ele subir"
fi
