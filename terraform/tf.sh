#!/usr/bin/env bash
#
# Wrapper do Terraform para os stacks deste repositório.
#
# Resolve, a partir do stack e do ambiente, o backend (bucket + key) e o
# tfvars corretos — e isola o diretório .terraform de cada ambiente, para
# que um `plan` em develop nunca use por engano o backend de production.
#
# Uso:
#   ./tf.sh bootstrap apply                  # 1x por conta (state local)
#   ./tf.sh global plan|apply                # 1x por conta
#   ./tf.sh infra <ambiente> plan|apply|destroy|output ...
#   ./tf.sh cluster-addons <ambiente> plan|apply|destroy|output ...
#
#   <ambiente> = develop | staging | production
#
# Exemplos:
#   ./tf.sh infra develop plan
#   ./tf.sh infra develop apply -auto-approve
#   ./tf.sh infra develop output -raw cluster_name
#
# Variáveis de ambiente opcionais:
#   TF_STATE_BUCKET  nome do bucket de state (default: togglemaster-tfstate-<account_id>)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENTS=(develop staging production)

die()   { echo -e "\033[1;31mERRO: $*\033[0m" >&2; exit 1; }
usage() { sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 1
[[ "$1" == "-h" || "$1" == "--help" ]] && usage 0

command -v terraform >/dev/null || die "terraform não encontrado"

STACK="$1"; shift
DIR="$ROOT/$STACK"
[[ -d "$DIR" ]] || die "stack desconhecido: $STACK (use bootstrap, global, infra ou cluster-addons)"

# --- bootstrap: state local, sem backend nem ambiente -----------------------
if [[ "$STACK" == "bootstrap" ]]; then
  [[ $# -ge 1 ]] || usage 1
  terraform -chdir="$DIR" init -input=false >/dev/null
  exec terraform -chdir="$DIR" "$@"
fi

# --- stacks com backend remoto ----------------------------------------------
case "$STACK" in
  global)
    ENV_NAME="global"
    BACKEND_FILE="$DIR/backend.s3.tfbackend"
    VAR_FILE="$DIR/terraform.tfvars"   # opcional (não versionado)
    ;;
  infra|cluster-addons)
    [[ $# -ge 1 ]] || die "informe o ambiente: ${ENVIRONMENTS[*]}"
    ENV_NAME="$1"; shift
    printf '%s\n' "${ENVIRONMENTS[@]}" | grep -qx "$ENV_NAME" \
      || die "ambiente inválido: $ENV_NAME (use ${ENVIRONMENTS[*]})"
    BACKEND_FILE="$DIR/envs/$ENV_NAME.s3.tfbackend"
    VAR_FILE="$DIR/envs/$ENV_NAME.tfvars"
    ;;
  *)
    die "stack desconhecido: $STACK"
    ;;
esac

[[ $# -ge 1 ]] || die "informe o comando do terraform (plan, apply, destroy, output...)"
COMMAND="$1"; shift

# O nome do bucket leva o account ID, então não precisa estar em nenhum
# arquivo versionado.
if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
  command -v aws >/dev/null || die "aws cli não encontrado (ou defina TF_STATE_BUCKET)"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
    || die "não foi possível identificar a conta AWS. Credenciais configuradas?"
  TF_STATE_BUCKET="togglemaster-tfstate-${ACCOUNT_ID}"
fi

# Um .terraform por ambiente: o backend de cada um fica "preso" ao seu
# diretório de dados, e trocar de ambiente não exige init -reconfigure.
export TF_DATA_DIR="$DIR/.terraform/$ENV_NAME"

if ! INIT_OUT="$(terraform -chdir="$DIR" init -input=false \
      -backend-config="$BACKEND_FILE" \
      -backend-config="bucket=$TF_STATE_BUCKET" 2>&1)"; then
  echo "$INIT_OUT" >&2
  die "terraform init falhou (o bucket $TF_STATE_BUCKET existe? rode ./tf.sh bootstrap apply)"
fi

# Só os comandos que aceitam -var-file recebem o tfvars do ambiente.
case "$COMMAND" in
  plan|apply|destroy|import|refresh|console)
    VAR_ARGS=()
    [[ -f "$VAR_FILE" ]] && VAR_ARGS=(-var-file="$VAR_FILE")
    echo -e "\033[1;34m==> terraform $COMMAND · stack=$STACK · ambiente=$ENV_NAME\033[0m" >&2
    exec terraform -chdir="$DIR" "$COMMAND" "${VAR_ARGS[@]}" "$@"
    ;;
  *)
    exec terraform -chdir="$DIR" "$COMMAND" "$@"
    ;;
esac
