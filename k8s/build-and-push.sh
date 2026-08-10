#!/usr/bin/env bash
#
# Build e push das imagens da aplicação para o ECR.
#
# Uso:
#   ./build-and-push.sh [TAG] [SERVIÇO...]
#
# Exemplos:
#   ./build-and-push.sh v1                       # os 5 serviços
#   ./build-and-push.sh v2 flag-service          # só um
#   ./build-and-push.sh v2 flag-service auth-service
#   ./build-and-push.sh $(git rev-parse --short HEAD)
#
# Os repositórios são IMMUTABLE: subir a mesma tag duas vezes falha de
# propósito. Ao iterar, use v2, v3… ou o short SHA do commit.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TAG="${1:-v1}"
shift || true

# Sem serviços na linha de comando, constrói todos.
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
  for svc in "${TARGETS[@]}"; do
    tm_is_valid_service "$svc" \
      || tm_die "serviço inválido: '$svc'. Válidos: ${TM_SERVICES[*]}"
  done
else
  TARGETS=("${TM_SERVICES[@]}")
fi

tm_check_deps terraform docker aws

REGISTRY="$(terraform -chdir="$TM_INFRA_DIR" output -raw ecr_registry)" \
  || tm_die "não foi possível ler o ECR. O módulo infra foi aplicado?"
REGION="$(echo "$REGISTRY" | cut -d. -f4)"

tm_log "Autenticando no ECR ($REGISTRY)"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# As imagens base (golang, alpine, python) vêm do ECR espelhado, não do
# Docker Hub — é o que mantém o build sem dependência de registro público.
# Rode ./mirror-images.sh antes, senão estas imagens não existem ainda.
BASE_REGISTRY="$REGISTRY/mirror/library"

tm_log "Construindo ${#TARGETS[@]} imagem(ns) com tag '$TAG'"
tm_info "imagens base: $BASE_REGISTRY"

for svc in "${TARGETS[@]}"; do
  tm_log "$svc:$TAG"

  [[ -d "$TM_REPO_ROOT/$svc" ]] \
    || tm_die "pasta não encontrada: $TM_REPO_ROOT/$svc (os repositórios estão clonados lado a lado?)"

  # --platform linux/amd64 explícito para o caso de você buildar de um Mac
  # com Apple Silicon: sem isso a imagem sai arm64, os nós não conseguem
  # executá-la, e o erro ("exec format error") não sugere a causa.
  docker build --platform linux/amd64 \
    --build-arg "BASE_REGISTRY=$BASE_REGISTRY" \
    -t "$REGISTRY/togglemaster/$svc:$TAG" \
    "$TM_REPO_ROOT/$svc"

  docker push "$REGISTRY/togglemaster/$svc:$TAG"
done

tm_log "Concluído"
if [[ ${#TARGETS[@]} -eq ${#TM_SERVICES[@]} ]]; then
  echo "  Deploy completo:  ./deploy.sh $TAG"
else
  for svc in "${TARGETS[@]}"; do
    echo "  Deploy isolado:   ./deploy-service.sh $svc $TAG"
  done
fi
