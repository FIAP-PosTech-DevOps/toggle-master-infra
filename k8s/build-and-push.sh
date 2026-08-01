#!/usr/bin/env bash
#
# Build e push das 5 imagens para o ECR.
#
# Uso:
#   ./build-and-push.sh [TAG]      # default: v1
#
# Lembre-se: os repositórios ECR são IMMUTABLE. Subir a mesma tag duas vezes
# falha de propósito. Ao iterar, use v2, v3... ou o short SHA do commit:
#   ./build-and-push.sh $(git rev-parse --short HEAD)
#
set -euo pipefail

TAG="${1:-v1}"
INFRA_DIR="$(cd "$(dirname "$0")/../terraform/infra" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SERVICES=(auth-service flag-service targeting-service evaluation-service analytics-service)

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

cd "$INFRA_DIR"
REGISTRY="$(terraform output -raw ecr_registry)"
REGION="$(echo "$REGISTRY" | cut -d. -f4)"

log "Autenticando no ECR ($REGISTRY)"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# As imagens base (golang, alpine, python) vêm do ECR espelhado, não do
# Docker Hub — é o que mantém o build sem dependência de registro público.
# Rode ./mirror-images.sh antes, senão estas imagens não existem ainda.
BASE_REGISTRY="$REGISTRY/mirror/library"
log "Imagens base virão de: $BASE_REGISTRY"

for svc in "${SERVICES[@]}"; do
  log "$svc:$TAG"
  # --platform linux/amd64 é explícito para o caso de você buildar de um Mac
  # com chip Apple Silicon: sem isso a imagem sai arm64 e os nós (amd64) não
  # conseguem executá-la, com um erro de "exec format error" difícil de ligar
  # à causa.
  docker build --platform linux/amd64 \
    --build-arg "BASE_REGISTRY=$BASE_REGISTRY" \
    -t "$REGISTRY/togglemaster/$svc:$TAG" \
    "$REPO_ROOT/$svc"
  docker push "$REGISTRY/togglemaster/$svc:$TAG"
done

log "Concluído. Agora rode: ./deploy.sh $TAG"
