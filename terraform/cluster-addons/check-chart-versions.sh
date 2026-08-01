#!/usr/bin/env bash
#
# Consulta os repositórios Helm e mostra, para cada chart usado neste módulo:
#   - a versão mais recente disponível
#   - a restrição kubeVersion declarada pelo chart
#
# Use a saída para preencher as variáveis *_chart_version no terraform.tfvars.
#
# Uso:
#   ./check-chart-versions.sh [VERSAO_K8S]     # default: 1.36
#
set -euo pipefail

K8S="${1:-1.36}"

command -v helm >/dev/null || { echo "helm não encontrado"; exit 1; }
command -v jq   >/dev/null || { echo "jq não encontrado"; exit 1; }

echo "Adicionando repositórios..."
helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx      >/dev/null 2>&1 || true
helm repo add eks            https://aws.github.io/eks-charts                >/dev/null 2>&1 || true
helm repo add kedacore       https://kedacore.github.io/charts               >/dev/null 2>&1 || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update >/dev/null

printf "\nSeu cluster: Kubernetes %s\n\n" "$K8S"
printf "%-42s %-14s %s\n" "CHART" "ÚLTIMA" "RESTRIÇÃO kubeVersion"
printf "%-42s %-14s %s\n" "-----" "------" "---------------------"

check() {
  local ref="$1"
  local ver kube

  ver="$(helm search repo "$ref" --output json 2>/dev/null \
        | jq -r --arg n "$ref" '.[] | select(.name==$n) | .version' | head -1)"

  if [[ -z "$ver" ]]; then
    printf "%-42s %-14s %s\n" "$ref" "?" "chart não encontrado no repo"
    return
  fi

  kube="$(helm show chart "$ref" --version "$ver" 2>/dev/null \
         | grep -i '^kubeVersion:' | cut -d: -f2- | xargs || true)"
  [[ -z "$kube" ]] && kube="(não declarada)"

  printf "%-42s %-14s %s\n" "$ref" "$ver" "$kube"
}

check "metrics-server/metrics-server"
check "eks/aws-load-balancer-controller"
check "ingress-nginx/ingress-nginx"
check "kedacore/keda"

cat <<EOF

Como ler:
  - "(não declarada)" significa que o chart não impõe restrição de versão de
    Kubernetes. Nesse caso use a mais recente sem medo.
  - Se a restrição for algo como ">= 1.29.0-0", basta que $K8S seja maior.
  - Se for uma faixa fechada tipo ">=1.29.0-0 <1.34.0-0", a última versão NÃO
    suporta o seu cluster. Aí procure uma versão mais nova do chart:
        helm search repo <chart> --versions | head -20

Depois de escolher, coloque no terraform.tfvars:

  metrics_server_chart_version = "X.Y.Z"
  alb_controller_chart_version = "X.Y.Z"
  ingress_nginx_chart_version  = "X.Y.Z"
  keda_chart_version           = "X.Y.Z"
EOF
