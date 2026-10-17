#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Instala e sobe o Backstage do laboratório (roda uma vez, pelo cloud-init).
# Log: /var/log/backstage-bootstrap.log
# -----------------------------------------------------------------------------
set -euo pipefail
source /opt/backstage/lab.env
export AWS_REGION

echo "==> pacotes (Docker)"
dnf install -y docker
systemctl enable --now docker

echo "==> kubectl (versão do EKS do projeto)"
KUBECTL_VERSION="$(curl -sSfL https://dl.k8s.io/release/stable-1.36.txt)"
curl -sSfL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

echo "==> segredos do SSM Parameter Store (/${PROJECT}/backstage/*)"
param() {
  aws ssm get-parameter --with-decryption --name "/${PROJECT}/backstage/$1" \
    --query Parameter.Value --output text
}
umask 077
POSTGRES_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cat > /opt/backstage/backstage.env <<ENV
AUTH_GITHUB_CLIENT_ID=$(param github-client-id)
AUTH_GITHUB_CLIENT_SECRET=$(param github-client-secret)
GITHUB_TOKEN=$(param github-token)
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_USER=backstage
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
AWS_REGION=${AWS_REGION}
NODE_OPTIONS=--max-old-space-size=2048
ENV
umask 022

echo "==> Postgres (só em 127.0.0.1)"
docker volume create backstage-pg >/dev/null
docker run -d --name postgres --restart unless-stopped --network host \
  -e POSTGRES_USER=backstage -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  -v backstage-pg:/var/lib/postgresql/data \
  public.ecr.aws/docker/library/postgres:16-alpine \
  -c listen_addresses=127.0.0.1
unset POSTGRES_PASSWORD
for _ in $(seq 1 30); do
  docker exec postgres pg_isready -h 127.0.0.1 -U backstage >/dev/null 2>&1 && break
  sleep 2
done

echo "==> imagem do Backstage: ${BACKSTAGE_IMAGE}"
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker pull "${BACKSTAGE_IMAGE}"

echo "==> clusters e ArgoCD no ar (gera app-config.lab.yaml)"
/opt/backstage/lab-refresh.sh --no-restart

echo "==> Backstage em 127.0.0.1:7007"
docker run -d --name backstage --restart unless-stopped --network host \
  --env-file /opt/backstage/backstage.env \
  -v /opt/backstage/app-config.lab.yaml:/app/app-config.lab.yaml:ro \
  "${BACKSTAGE_IMAGE}" \
  node packages/backend --config app-config.yaml --config app-config.production.yaml --config app-config.lab.yaml

# Reavalia os clusters a cada 2 minutos: ambiente que sobe entra sozinho.
systemctl daemon-reload
systemctl enable --now backstage-refresh.timer
echo "==> pronto"
