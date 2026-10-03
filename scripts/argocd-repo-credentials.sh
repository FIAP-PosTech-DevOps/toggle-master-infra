#!/usr/bin/env bash
#
# Cadastra no ArgoCD a credencial de LEITURA do repositório GitOps.
#
# Só é necessário se o toggle-master-gitops for PRIVADO. Repositório público
# o ArgoCD lê sem credencial, e este script pode ser ignorado.
#
# A credencial é um fine-grained personal access token do GitHub com acesso
# APENAS ao repositório toggle-master-gitops e permissão "Contents: Read-only".
# Ele é lido de uma variável de ambiente (não fica no histórico do shell nem
# em arquivo) e vira um Secret no namespace argocd.
#
# Uso:
#   read -rs GITOPS_TOKEN && export GITOPS_TOKEN
#   ./scripts/argocd-repo-credentials.sh <develop|staging|production>
#
set -euo pipefail

ENVIRONMENT="${1:-}"
REPO_URL="${GITOPS_REPO_URL:-https://github.com/FIAP-PosTech-DevOps/toggle-master-gitops.git}"

die() { echo -e "\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

case "$ENVIRONMENT" in
  develop|staging|production) ;;
  *) sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

[[ -n "${GITOPS_TOKEN:-}" ]] || die "defina GITOPS_TOKEN (read -rs GITOPS_TOKEN && export GITOPS_TOKEN)"

for cmd in aws kubectl jq; do
  command -v "$cmd" >/dev/null || die "'$cmd' não encontrado"
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUTS="$("$ROOT/terraform/tf.sh" infra "$ENVIRONMENT" output -json)" \
  || die "não foi possível ler os outputs do stack infra de $ENVIRONMENT"

REGION="$(jq -r .aws_region.value <<<"$OUTPUTS")"
CLUSTER="$(jq -r .cluster_name.value <<<"$OUTPUTS")"
CONTEXT="togglemaster-${ENVIRONMENT}"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CONTEXT" >/dev/null

# O token entra pelo stdin (--from-file=/dev/stdin), nunca como argumento de
# linha de comando, que ficaria visível na lista de processos.
printf '%s' "$GITOPS_TOKEN" | kubectl --context "$CONTEXT" -n argocd create secret generic repo-toggle-master-gitops \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username=git \
    --from-file=password=/dev/stdin \
    --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl --context "$CONTEXT" apply -f -

echo "credencial do repositório GitOps cadastrada no ArgoCD de $ENVIRONMENT"
