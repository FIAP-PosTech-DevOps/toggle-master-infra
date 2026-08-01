#!/usr/bin/env bash
#
# Espelha para o ECR privado as imagens de terceiros cujo upstream exigiria
# credencial para pull-through cache (ghcr.io e Docker Hub).
#
# As demais (registry.k8s.io e public.ecr.aws) são resolvidas automaticamente
# pelas regras de pull-through criadas no Terraform — não precisam deste script.
#
# Quando rodar:
#   - depois do `terraform apply` do infra (os repositórios ECR precisam existir)
#   - ANTES do `terraform apply` do cluster-addons (o KEDA aponta para o espelho)
#   - a cada ciclo, porque o `terraform destroy` remove os repositórios
#
# Uso:
#   ./mirror-images.sh [VERSAO_KEDA]      # default: 2.20.1
#
set -euo pipefail

KEDA_VERSION="${1:-2.20.1}"
INFRA_DIR="$(cd "$(dirname "$0")/../terraform/infra" && pwd)"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
die() { echo -e "\n\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

command -v docker >/dev/null || die "docker não encontrado"

cd "$INFRA_DIR"
REGISTRY="$(terraform output -raw ecr_registry)"
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

  # Cria o repositório se ainda não existir. MUTABLE de propósito: espelho é
  # cópia de upstream, e reespelhar a mesma tag num novo ciclo é o normal.
  # (Os repositórios das SUAS imagens continuam IMMUTABLE — ver ecr.tf.)
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository \
         --repository-name "$repo" \
         --region "$REGION" \
         --image-scanning-configuration scanOnPush=true \
         --image-tag-mutability MUTABLE >/dev/null

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
  cd ../terraform/cluster-addons && terraform apply
EOF
