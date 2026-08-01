#!/usr/bin/env bash
#
# Remove a aplicação do cluster, na ordem correta.
#
# Rode ANTES do `terraform destroy` do cluster-addons. Motivo:
#
#   O `helm uninstall keda` apaga os CRDs do KEDA. Para apagar um CRD, o
#   Kubernetes precisa antes remover todos os recursos daquele tipo — e o
#   ScaledObject/TriggerAuthentication têm finalizers que SÓ o operador do
#   KEDA sabe liberar. Se o operador for removido primeiro, ninguém libera os
#   finalizers e o destroy trava até estourar o timeout.
#
# Uso:
#   ./destroy.sh
#
set -euo pipefail

NAMESPACE="togglemaster"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

command -v kubectl >/dev/null || { echo "kubectl não encontrado"; exit 1; }

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  log "Namespace '$NAMESPACE' não existe — nada a fazer"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Recursos do KEDA primeiro, com o operador ainda vivo
# ---------------------------------------------------------------------------
log "Removendo ScaledObject e TriggerAuthentication"
kubectl delete scaledobject --all -n "$NAMESPACE" --ignore-not-found --timeout=60s || true
kubectl delete triggerauthentication --all -n "$NAMESPACE" --ignore-not-found --timeout=60s || true

# Rede de segurança: se algo ficou preso em Terminating, libera o finalizer.
for kind in scaledobject triggerauthentication; do
  for r in $(kubectl get "$kind" -n "$NAMESPACE" -o name 2>/dev/null || true); do
    echo "  liberando finalizer de $r"
    kubectl patch "$r" -n "$NAMESPACE" --type=merge \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
done

# ---------------------------------------------------------------------------
# 2. Ingress antes do resto
# ---------------------------------------------------------------------------
# O Ingress em si não cria Load Balancer (quem cria é o Service do
# ingress-nginx), mas removê-lo primeiro evita que o controller fique
# reconciliando regras para Services que estão sumindo.
log "Removendo Ingress"
kubectl delete ingress --all -n "$NAMESPACE" --ignore-not-found --timeout=60s || true

# ---------------------------------------------------------------------------
# 3. HPA, workloads e configuração
# ---------------------------------------------------------------------------
log "Removendo HPA"
kubectl delete hpa --all -n "$NAMESPACE" --ignore-not-found --timeout=60s || true

log "Removendo Deployments e Services"
kubectl delete deployment --all -n "$NAMESPACE" --ignore-not-found --timeout=120s || true
kubectl delete service --all -n "$NAMESPACE" --ignore-not-found --timeout=60s || true

log "Removendo ConfigMap e Secrets"
kubectl delete configmap togglemaster-config -n "$NAMESPACE" --ignore-not-found || true
for s in auth-service-secret flag-service-secret targeting-service-secret evaluation-service-secret; do
  kubectl delete secret "$s" -n "$NAMESPACE" --ignore-not-found || true
done

# Pods avulsos deixados por testes (load-1, pgtest, irsa-ok...)
log "Removendo pods de teste"
kubectl delete pod --all -n "$NAMESPACE" --ignore-not-found --timeout=60s || true

# ---------------------------------------------------------------------------
# 4. O namespace e as Service Accounts NÃO são removidos aqui
# ---------------------------------------------------------------------------
# Eles pertencem ao módulo cluster-addons (namespace.tf) e serão destruídos
# pelo `terraform destroy`. Apagar o namespace aqui deixaria o state do
# Terraform inconsistente.

log "Estado restante no namespace"
kubectl get all -n "$NAMESPACE" 2>/dev/null || true

cat <<EOF

Aplicação removida. Agora:

  cd \$INFRA/terraform/cluster-addons && terraform destroy
  cd \$INFRA/terraform/infra          && terraform destroy
EOF
