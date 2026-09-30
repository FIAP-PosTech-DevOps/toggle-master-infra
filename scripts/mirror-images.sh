#!/usr/bin/env bash
#
# Espelha para o ECR compartilhado as imagens de terceiros cujo upstream
# exigiria credencial para pull-through cache (ghcr.io e Docker Hub).
#
# As demais (registry.k8s.io e public.ecr.aws) são resolvidas automaticamente
# pelas regras de pull-through do stack global — não precisam deste script.
#
# Os repositórios mirror/* são criados pelo Terraform (stack global,
# variável mirror_repositories). Este script só publica as imagens neles.
#
# Quando rodar:
#   - uma vez, depois do `tf.sh global apply`
#   - de novo só ao trocar a versão do KEDA ou das imagens base
#   (o ECR é compartilhado e não é destruído junto com os ambientes)
#
# Uso:
#   ./scripts/mirror-images.sh [VERSAO_KEDA]      # default: 2.20.1
#
set -euo pipefail

KEDA_VERSION="${1:-2.20.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
die() { echo -e "\n\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

command -v docker >/dev/null || die "docker não encontrado"

REGISTRY="$("$ROOT/terraform/tf.sh" global output -raw ecr_registry)" \
  || die "não foi possível ler o output do stack global. Ele foi aplicado?"
REGION="$(echo "$REGISTRY" | cut -d. -f4)"

# Pares "origem|destino_sem_registry".
# O destino fica sob o prefixo mirror/, que é o que os charts e Dockerfiles
# esperam (ver locals.tf do cluster-addons e o ARG BASE_REGISTRY).
IMAGES=(
  # --- KEDA (ghcr.io exige credencial para pull-through) ---
  "ghcr.io/kedacore/keda:${KEDA_VERSION}|mirror/kedacore/keda:${KEDA_VERSION}"
  "ghcr.io/kedacore/keda-metrics-apiserver:${KEDA_VERSION}|mirror/kedacore/keda-metrics-apiserver:${KEDA_VERSION}"
  "ghcr.io/kedacore/keda-admission-webhooks:${KEDA_VERSION}|mirror/kedacore/keda-admission-webhooks:${KEDA_VERSION}"

  # --- Imagens base dos Dockerfiles (Docker Hub) ---
  "golang:1.21-alpine|mirror/library/golang:1.21-alpine"
  "alpine:3.19|mirror/library/alpine:3.19"
  "python:3.9-slim|mirror/library/python:3.9-slim"

  # --- Utilitários usados pelo deploy.sh e pelos testes ---
  "postgres:15-alpine|mirror/library/postgres:15-alpine"
  "redis:7-alpine|mirror/library/redis:7-alpine"
)

log "Autenticando no ECR ($REGISTRY)"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

log "Espelhando ${#IMAGES[@]} imagens"
for pair in "${IMAGES[@]}"; do
  src="${pair%%|*}"
  dst_path="${pair##*|}"
  repo="${dst_path%%:*}"
  dst="$REGISTRY/$dst_path"

  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
    || die "repositório $repo não existe. Inclua-o em mirror_repositories (terraform/global) e aplique."

  echo "  $src"
  echo "    -> $dst"
  # --platform explícito: garante amd64 mesmo se você rodar de um Mac ARM.
  docker pull --platform linux/amd64 -q "$src" >/dev/null
  docker tag "$src" "$dst"
  docker push -q "$dst" >/dev/null
done

log "Concluído"
cat <<EOF
Agora todas as imagens de terceiros vêm do seu ECR privado:

  registry.k8s.io   -> $REGISTRY/k8s/...          (pull-through automático)
  public.ecr.aws    -> $REGISTRY/ecr-public/...   (pull-through automático)
  ghcr.io           -> $REGISTRY/mirror/...       (espelhado por este script)
  docker.io         -> $REGISTRY/mirror/library/... (espelhado por este script)

Próximo passo:
  ./terraform/tf.sh cluster-addons <ambiente> apply
EOF
