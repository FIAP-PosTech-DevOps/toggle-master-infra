#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Descobre quais ambientes estão no ar e gera /opt/backstage/app-config.lab.yaml
# com os clusters (plugin de Kubernetes) e os ArgoCD (plugin do Argo CD).
#
# Para cada ambiente com cluster EKS ativo:
#   - endpoint + CA do cluster;
#   - port-forward até o argocd-server (systemd argocd-pf@<ambiente>);
#   - senha do admin do ArgoCD (Secret argocd-initial-admin-secret).
# Ambiente fora do ar: port-forward parado e entrada removida.
#
# Se o arquivo mudou, reinicia o container do Backstage. Roda no boot e a cada
# 2 minutos (backstage-refresh.timer). --no-restart: só gera o arquivo.
# -----------------------------------------------------------------------------
set -uo pipefail
source /opt/backstage/lab.env

OUT=/opt/backstage/app-config.lab.yaml
KUBECONFIG=/opt/backstage/kubeconfig
export KUBECONFIG
TMP="$(mktemp)"
CLUSTERS=""
INSTANCES=""

for spec in ${ENVIRONMENTS}; do
  IFS=: read -r env region port <<<"$spec"
  cluster="${PROJECT}-${env}-cluster"

  read -r status endpoint ca < <(aws eks describe-cluster --region "$region" --name "$cluster" \
    --query 'cluster.[status,endpoint,certificateAuthority.data]' --output text 2>/dev/null || echo "NONE")
  if [[ "$status" != "ACTIVE" ]]; then
    systemctl stop "argocd-pf@${env}" 2>/dev/null || true
    continue
  fi

  aws eks update-kubeconfig --region "$region" --name "$cluster" --alias "$env" >/dev/null
  CLUSTERS+="
        - name: ${env}
          title: '${env} (${region})'
          url: ${endpoint}
          authProvider: aws
          skipMetricsLookup: true
          authMetadata:
            kubernetes.io/x-k8s-aws-id: ${cluster}
          caData: ${ca}"

  # ArgoCD: só entra se a senha estiver acessível (cluster-addons aplicado).
  password="$(kubectl --context "$env" -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [[ -n "$password" ]]; then
    echo "PORT=${port}" > "/opt/backstage/pf-${env}.env"
    systemctl start "argocd-pf@${env}"
    INSTANCES+="
        - name: ${env}
          url: http://127.0.0.1:${port}
          username: admin
          password: '${password}'"
  else
    systemctl stop "argocd-pf@${env}" 2>/dev/null || true
  fi
done

umask 077
cat > "$TMP" <<YAML
# Gerado por lab-refresh.sh em $(date -u +%FT%TZ). Não editar à mão.
kubernetes:
  clusterLocatorMethods:
    - type: config
      clusters:${CLUSTERS:- []}
argocd:
  appLocatorMethods:
    - type: config
      instances:${INSTANCES:- []}
YAML
# O container roda como usuário "node" (uid 1000): precisa ler o arquivo.
chown 1000:1000 "$TMP"; chmod 0400 "$TMP"

# Compara ignorando a linha da data.
if [[ -f "$OUT" ]] && diff -q <(tail -n +2 "$OUT") <(tail -n +2 "$TMP") >/dev/null; then
  rm -f "$TMP"
  exit 0
fi
mv -f "$TMP" "$OUT"
echo "app-config.lab.yaml atualizado: $(grep -c 'authProvider' "$OUT") cluster(s), $(grep -c 'username: admin' "$OUT") ArgoCD"

if [[ "${1:-}" != "--no-restart" ]] && docker inspect backstage >/dev/null 2>&1; then
  docker restart backstage >/dev/null
  echo "Backstage reiniciado com a nova configuração"
fi
