#!/usr/bin/env bash
#
# Prepara o ambiente local do zero, num comando só.
#
#     ./local-bootstrap.sh
#
# Faz, em sequência:
#   1. cria o .env a partir do .env.example, se não existir
#   2. gera MASTER_KEY e POSTGRES_PASSWORD, se ainda estiverem no valor de exemplo
#   3. sobe os containers, se não estiverem no ar
#   4. espera o auth-service responder
#   5. cria a SERVICE_API_KEY e grava no .env
#   6. recria o evaluation-service para carregá-la
#
# É idempotente: rodar de novo não estraga nada. As credenciais já geradas
# são preservadas; apenas a SERVICE_API_KEY é renovada.
#
# Opções:
#   --skip-up      não sobe os containers (assume que já estão rodando)
#   --reset-keys   regenera também MASTER_KEY e POSTGRES_PASSWORD
#
# Por que a SERVICE_API_KEY não pode ser fixa: o auth-service guarda apenas o
# hash SHA-256 da chave (auth-service/key.go). Hash é via única — não dá para
# inventar uma chave e esperar que valide. Ela precisa ser criada por
# POST /admin/keys para que exista a linha correspondente em api_keys. Por
# isso, depois de `docker compose down -v` (que apaga o volume e a tabela),
# é necessário rodar este script de novo.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

AUTH_URL="http://localhost:8001"
ENV_FILE=".env"
EXAMPLE_FILE=".env.example"
PLACEHOLDER="troque-esta-chave"

SKIP_UP=false
RESET_KEYS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-up)    SKIP_UP=true ;;
    --reset-keys) RESET_KEYS=true ;;
    -h|--help)    sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *)            echo "opção desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
info() { echo "  $*"; }
die()  { echo -e "\n\033[1;31mERRO: $*\033[0m" >&2; exit 1; }

for cmd in docker curl jq python3 openssl; do
  command -v "$cmd" >/dev/null || die "'$cmd' não encontrado"
done

# Grava uma variável no .env sem depender de escaping — python3 em vez de sed.
set_env_var() {
  python3 - "$1" "$2" "$ENV_FILE" <<'PY'
import sys
name, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
found = False
for i, line in enumerate(lines):
    if line.startswith(f"{name}="):
        lines[i] = f"{name}={value}"
        found = True
if not found:
    lines.append(f"{name}={value}")
open(path, "w").write("\n".join(lines) + "\n")
PY
}

get_env_var() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# ---------------------------------------------------------------------------
# 1. .env
# ---------------------------------------------------------------------------
log "Arquivo .env"
if [[ -f "$ENV_FILE" ]]; then
  info "já existe, preservando"
else
  [[ -f "$EXAMPLE_FILE" ]] || die "$EXAMPLE_FILE não encontrado"
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  info "criado a partir de $EXAMPLE_FILE"
fi

# ---------------------------------------------------------------------------
# 2. Credenciais locais
# ---------------------------------------------------------------------------
log "Credenciais"

CURRENT_MASTER="$(get_env_var MASTER_KEY)"
if [[ "$RESET_KEYS" == true || -z "$CURRENT_MASTER" || "$CURRENT_MASTER" == "$PLACEHOLDER" ]]; then
  set_env_var MASTER_KEY "$(openssl rand -hex 24)"
  info "MASTER_KEY gerada"
else
  info "MASTER_KEY preservada"
fi

CURRENT_PG="$(get_env_var POSTGRES_PASSWORD)"
if [[ "$RESET_KEYS" == true || -z "$CURRENT_PG" || "$CURRENT_PG" == "postgrespassword" ]]; then
  # O Postgres só aplica POSTGRES_PASSWORD ao inicializar um banco vazio.
  # Este compose não declara volumes nomeados, então os dados vivem na camada
  # de escrita do container: ao mudar a variável, o Compose recria o container
  # e o banco nasce de novo com a senha nova. Se um dia forem adicionados
  # volumes persistentes, esta verificação evita gerar uma senha que o banco
  # existente rejeitaria.
  if [[ -n "$CURRENT_PG" ]] && docker volume ls -q 2>/dev/null | grep -q "postgres"; then
    info "POSTGRES_PASSWORD mantida (há volume persistente; trocar exigiria 'docker compose down -v')"
  else
    set_env_var POSTGRES_PASSWORD "$(openssl rand -hex 16)"
    info "POSTGRES_PASSWORD gerada"
  fi
else
  info "POSTGRES_PASSWORD preservada"
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# ---------------------------------------------------------------------------
# 3. Containers
# ---------------------------------------------------------------------------
if [[ "$SKIP_UP" == false ]]; then
  log "Subindo os containers"
  docker compose up -d
else
  info "--skip-up: assumindo containers já no ar"
fi

# ---------------------------------------------------------------------------
# 4. Esperar o auth-service
# ---------------------------------------------------------------------------
# Com os healthchecks do compose, o `up -d` acima já espera o Postgres ficar
# pronto antes de iniciar o auth-service. Esta espera cobre só o tempo de boot
# da aplicação em si.
log "Aguardando o auth-service"
TIMEOUT=90
for i in $(seq 1 $TIMEOUT); do
  if curl -sf "$AUTH_URL/health" >/dev/null 2>&1; then
    info "respondendo após ${i}s"
    break
  fi
  if [[ $i -eq $TIMEOUT ]]; then
    echo "" >&2
    docker compose ps auth-service >&2 || true
    echo "" >&2
    docker compose logs auth-service --tail=20 >&2 || true
    die "auth-service não respondeu em ${TIMEOUT}s (logs acima)"
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# 5. SERVICE_API_KEY
# ---------------------------------------------------------------------------
log "Criando SERVICE_API_KEY"

RESP="$(curl -s -X POST "$AUTH_URL/admin/keys" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"evaluation-service"}')"

NEW_KEY="$(echo "$RESP" | jq -r .key 2>/dev/null || true)"

if [[ -z "$NEW_KEY" || "$NEW_KEY" == "null" ]]; then
  echo "Resposta do auth-service: ${RESP:-<vazia>}" >&2
  die "não foi possível criar a chave.
  Se a resposta foi 'Acesso não autorizado', o container está com uma
  MASTER_KEY diferente da que está no .env (ele subiu antes da geração).
  Recrie e rode de novo:
    docker compose up -d --force-recreate auth-service && ./local-bootstrap.sh"
fi

# Formato esperado: tm_key_ + 64 hex (ver auth-service/key.go). Validar evita
# gravar lixo no .env se a resposta mudar ou vier truncada.
[[ "$NEW_KEY" =~ ^tm_key_[0-9a-f]{64}$ ]] \
  || die "chave em formato inesperado: $NEW_KEY"

set_env_var SERVICE_API_KEY "$NEW_KEY"
info "chave criada e gravada: ${NEW_KEY:0:16}…"

# ---------------------------------------------------------------------------
# 6. Recriar o evaluation-service
# ---------------------------------------------------------------------------
# Variável de ambiente é resolvida na criação do container: sem recriar, ele
# continuaria com o valor antigo (ou vazio).
log "Recriando o evaluation-service"
docker compose up -d --force-recreate evaluation-service >/dev/null

# ---------------------------------------------------------------------------
# Pronto
# ---------------------------------------------------------------------------
log "Ambiente pronto"
docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null || docker compose ps

cat <<EOF

Teste a cadeia completa:

  API_KEY=\$(grep ^SERVICE_API_KEY= .env | cut -d= -f2)

  curl -s -X POST localhost:8002/flags \\
    -H "Authorization: Bearer \$API_KEY" \\
    -H 'Content-Type: application/json' \\
    -d '{"name":"teste","description":"local","is_enabled":true}' | jq

  curl -s -X POST localhost:8003/rules \\
    -H "Authorization: Bearer \$API_KEY" \\
    -H 'Content-Type: application/json' \\
    -d '{"flag_name":"teste","rules":{"type":"PERCENTAGE","value":50}}' | jq

  curl -s "localhost:8004/evaluate?user_id=u1&flag_name=teste" | jq
EOF
