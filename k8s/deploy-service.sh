#!/usr/bin/env bash
#
# Deploy de um ou mais microsserviços, sem tocar nos demais.
#
# É o caminho para o cenário real de "corrigi um bug no flag-service, quero
# subir só ele". Não mexe no Ingress nem no ConfigMap compartilhado (esses são
# responsabilidade do deploy.sh).
#
# Uso:
#   ./deploy-service.sh <serviço...> [tag] [--with-schema]
#
# A ordem dos argumentos é livre: nomes de serviço são reconhecidos pela lista
# conhecida, e o argumento restante vira a tag.
#
# Exemplos:
#   ./deploy-service.sh flag-service v3
#   ./deploy-service.sh flag-service targeting-service v3
#   ./deploy-service.sh auth-service v2 --with-schema
#   ./deploy-service.sh evaluation-service $(git rev-parse --short HEAD)
#
# Serviços válidos:
#   auth-service  flag-service  targeting-service
#   evaluation-service  analytics-service
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
REQUESTED=()
IMAGE_TAG=""
WITH_SCHEMA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-schema)
      WITH_SCHEMA=true
      ;;
    -h|--help)
      sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      tm_die "opção desconhecida: $1"
      ;;
    *)
      if tm_is_valid_service "$1"; then
        REQUESTED+=("$1")
      elif [[ -z "$IMAGE_TAG" ]]; then
        IMAGE_TAG="$1"
      else
        tm_die "argumento não reconhecido: '$1'
  Não é um serviço válido (${TM_SERVICES[*]}) e a tag já foi definida como '$IMAGE_TAG'."
      fi
      ;;
  esac
  shift
done

[[ ${#REQUESTED[@]} -gt 0 ]] \
  || tm_die "informe ao menos um serviço.
  Ex: ./deploy-service.sh flag-service v2
  Válidos: ${TM_SERVICES[*]}"

IMAGE_TAG="${IMAGE_TAG:-v1}"
export IMAGE_TAG

# Reordena pela dependência e remove duplicatas: se o auth-service estiver no
# conjunto, ele precisa subir antes do evaluation-service.
mapfile -t SERVICES < <(tm_sort_services "${REQUESTED[@]}")

tm_check_deps terraform kubectl aws jq envsubst python3
tm_check_cluster

if [[ ${#SERVICES[@]} -eq 1 ]]; then
  tm_log "Deploy isolado: ${SERVICES[0]}:$IMAGE_TAG"
else
  tm_log "Deploy de ${#SERVICES[@]} serviços — tag $IMAGE_TAG"
  tm_info "ordem: ${SERVICES[*]}"
fi

# ---------------------------------------------------------------------------
# Resumo, impresso mesmo se algum serviço falhar no meio
# ---------------------------------------------------------------------------
DONE_LIST=()
_summary() {
  local rc=$?
  if [[ ${#SERVICES[@]} -gt 1 || $rc -ne 0 ]]; then
    echo ""
    echo "─── Resumo ───"
    local s
    for s in "${SERVICES[@]}"; do
      if printf '%s\n' "${DONE_LIST[@]}" | grep -qx "$s" 2>/dev/null; then
        printf "  \033[1;32m✓\033[0m %s\n" "$s"
      else
        printf "  \033[1;31m✗\033[0m %s\n" "$s"
      fi
    done
  fi
  return $rc
}
trap _summary EXIT

# ---------------------------------------------------------------------------
# Preparação comum (uma vez, não por serviço)
# ---------------------------------------------------------------------------
tm_load_outputs

# ConfigMap só é criado se faltar. Num deploy isolado não queremos reescrever
# configuração que pertence a todos os serviços.
if ! kubectl get configmap togglemaster-config -n "$TM_NAMESPACE" >/dev/null 2>&1; then
  tm_warn "ConfigMap togglemaster-config não existia — criando"
  tm_apply_configmap
fi

# ---------------------------------------------------------------------------
# Deploy de um serviço
# ---------------------------------------------------------------------------
deploy_one() {
  local svc="$1"
  local db_key manifest autoscaler

  tm_log "$svc:$IMAGE_TAG"

  # 1. A imagem existe no ECR?
  # Verificar antes evita subir um Deployment que ficaria em ImagePullBackOff.
  aws ecr describe-images --repository-name "togglemaster/$svc" \
      --image-ids imageTag="$IMAGE_TAG" --region "$AWS_REGION" >/dev/null 2>&1 \
    || tm_die "imagem togglemaster/$svc:$IMAGE_TAG não existe no ECR.
  Publique antes com: ./build-and-push.sh $IMAGE_TAG $svc"
  tm_info "imagem confirmada no ECR"

  # 2. Schema (opcional)
  if [[ "$WITH_SCHEMA" == true ]]; then
    tm_load_schema "$svc"
  fi

  # 3. Secret do serviço
  db_key="$(tm_db_key_of "$svc")"
  case "$svc" in
    auth-service)
      # tm_master_key preserva a chave existente. Gerar uma nova a cada deploy
      # invalidaria a que você já tem anotada e quebraria o /admin/keys.
      tm_put_secret auth-service-secret \
        "DATABASE_URL=$(tm_db_url "$db_key")" \
        "MASTER_KEY=$(tm_master_key)"
      tm_info "Secret atualizado (MASTER_KEY preservada)"
      ;;
    flag-service|targeting-service)
      tm_put_secret "${svc}-secret" "DATABASE_URL=$(tm_db_url "$db_key")"
      tm_info "Secret atualizado"
      ;;
    evaluation-service)
      if ! tm_secret_exists evaluation-service-secret; then
        tm_warn "SERVICE_API_KEY não existe — gerando agora"
        "$TM_K8S_DIR/bootstrap-apikey.sh"
      else
        tm_info "SERVICE_API_KEY preservada"
      fi
      ;;
    analytics-service)
      # Não usa Secret: acesso à AWS por IRSA, endpoints pelo ConfigMap.
      tm_info "sem Secret (IRSA + ConfigMap)"
      ;;
  esac

  # 4. Manifesto + autoscaler
  manifest="$(tm_manifest_of "$svc")"
  envsubst < "$TM_K8S_DIR/$manifest" | kubectl apply -f -

  # HPA e ScaledObject acompanham o serviço: fazem parte do contrato de escala
  # dele, não da plataforma.
  autoscaler="$(tm_autoscaler_of "$svc")"
  if [[ -n "$autoscaler" ]]; then
    tm_info "aplicando $autoscaler"
    envsubst < "$TM_K8S_DIR/$autoscaler" | kubectl apply -f -
  fi

  # 5. Rollout
  tm_rollout "$svc"

  DONE_LIST+=("$svc")
}

for svc in "${SERVICES[@]}"; do
  deploy_one "$svc"
done

# ---------------------------------------------------------------------------
# Estado final
# ---------------------------------------------------------------------------
tm_log "Estado"
for svc in "${SERVICES[@]}"; do
  kubectl get pods -n "$TM_NAMESPACE" -l "app=$svc" -o wide --no-headers 2>/dev/null || true
done

echo ""
echo "Imagens em uso:"
for svc in "${SERVICES[@]}"; do
  printf "  %-20s %s\n" "$svc" \
    "$(kubectl get deploy "$svc" -n "$TM_NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')"
done

echo ""
echo "Para reverter algum deles:"
for svc in "${SERVICES[@]}"; do
  echo "  kubectl rollout undo deploy/$svc -n $TM_NAMESPACE"
done
