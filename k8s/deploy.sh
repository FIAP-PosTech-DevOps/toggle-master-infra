#!/usr/bin/env bash
#
# Deploy completo dos 5 microsserviços do ToggleMaster.
#
# É um orquestrador: cuida do que é COMPARTILHADO (schemas, ConfigMap,
# bootstrap da API key, Ingress) e delega cada serviço ao deploy-service.sh.
# Para subir um serviço só, use o deploy-service.sh diretamente.
#
# Pré-requisitos (nesta ordem):
#   1. terraform apply em ../terraform/infra
#   2. aws eks update-kubeconfig
#   3. ./mirror-images.sh
#   4. terraform apply em ../terraform/cluster-addons
#   5. ./build-and-push.sh
#
# Uso:
#   ./deploy.sh [TAG_DA_IMAGEM]     # default: v1
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_TAG="${1:-v1}"
export IMAGE_TAG

tm_check_deps terraform kubectl aws jq envsubst python3 openssl curl
tm_check_cluster

tm_log "Deploy completo — tag $IMAGE_TAG"

# ---------------------------------------------------------------------------
# 1. Outputs do Terraform
# ---------------------------------------------------------------------------
tm_load_outputs
tm_info "Tag:      $IMAGE_TAG"

# ---------------------------------------------------------------------------
# 2. Schemas dos bancos
# ---------------------------------------------------------------------------
# Necessário a cada ciclo: o terraform apply recria os RDS vazios.
tm_log "Carregando schemas (init.sql)"
for svc in auth-service flag-service targeting-service; do
  tm_load_schema "$svc"
done

# ---------------------------------------------------------------------------
# 3. ConfigMap compartilhado
# ---------------------------------------------------------------------------
tm_apply_configmap

# ---------------------------------------------------------------------------
# 4. Fase 1 — auth-service
# ---------------------------------------------------------------------------
# Precisa vir primeiro: a tabela api_keys nasce vazia e a SERVICE_API_KEY que
# o evaluation-service usa só pode ser criada com o auth-service no ar.
tm_log "Fase 1 — auth-service"
"$TM_K8S_DIR/deploy-service.sh" auth-service "$IMAGE_TAG"

# ---------------------------------------------------------------------------
# 5. Bootstrap da chave de serviço
# ---------------------------------------------------------------------------
# --force garante uma chave nova a cada deploy completo. Num deploy isolado o
# comportamento é o oposto: preserva a existente.
tm_log "Fase 2 — SERVICE_API_KEY"
"$TM_K8S_DIR/bootstrap-apikey.sh" --force

# ---------------------------------------------------------------------------
# 6. Fase 3 — demais serviços
# ---------------------------------------------------------------------------
tm_log "Fase 3 — demais serviços"
for svc in flag-service targeting-service evaluation-service analytics-service; do
  "$TM_K8S_DIR/deploy-service.sh" "$svc" "$IMAGE_TAG"
done

# ---------------------------------------------------------------------------
# 7. Ingress
# ---------------------------------------------------------------------------
# Fica aqui, e não no deploy-service.sh, porque referencia os 5 serviços: um
# deploy individual não deveria reescrever o roteamento de todo mundo.
tm_log "Aplicando Ingress"
envsubst < "$TM_K8S_DIR/07-ingress.yaml" | kubectl apply -f -

# ---------------------------------------------------------------------------
# 8. Resultado
# ---------------------------------------------------------------------------
tm_log "Estado final"
kubectl get pods -n "$TM_NAMESPACE" -o wide
kubectl get hpa,scaledobject -n "$TM_NAMESPACE"

tm_log "URL pública"
tm_print_nlb

cat <<EOF

A MASTER_KEY deste ambiente fica no Secret e é recuperada automaticamente:

  source $TM_K8S_DIR/env.sh

Para subir um serviço isolado depois:

  ./deploy-service.sh flag-service v2
EOF
