#!/usr/bin/env bash
#
# Define as variáveis de ambiente usadas pelos comandos de teste e validação
# do README (seções 5 e 6).
#
# USO — precisa ser carregado com `source`, não executado:
#
#     source $INFRA/k8s/env.sh
#
# Executar com `./env.sh` não funciona: o script rodaria num subshell e as
# variáveis morreriam junto com ele.
#
# Os valores mudam a cada ciclo de apply/destroy (a AWS gera sufixos
# aleatórios nos endpoints, e o deploy.sh sorteia uma MASTER_KEY nova), por
# isso são lidos ao vivo em vez de ficarem fixos em algum arquivo.

# Detecta se foi executado em vez de carregado.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERRO: use 'source ${BASH_SOURCE[0]}' em vez de executar o script." >&2
  exit 1
fi

_env_infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_env_tf="$_env_infra/terraform/infra"
_env_ns="togglemaster"
_env_falhas=0

echo "Lendo configuração de $_env_tf"

# --- Outputs do Terraform ---------------------------------------------------
if [[ -d "$_env_tf" ]]; then
  # 2>/dev/null: se o recurso não existe no state, o output falha e a
  # variável fica vazia — a conferência no final avisa.
  export ECR="$(terraform -chdir="$_env_tf" output -raw ecr_registry 2>/dev/null || true)"
  export QUEUE="$(terraform -chdir="$_env_tf" output -raw sqs_queue_url 2>/dev/null || true)"
  export TABLE="$(terraform -chdir="$_env_tf" output -raw dynamodb_table_name 2>/dev/null || true)"
  export REDIS="$(terraform -chdir="$_env_tf" output -raw redis_endpoint 2>/dev/null || true)"
  export CLUSTER="$(terraform -chdir="$_env_tf" output -raw cluster_name 2>/dev/null || true)"
else
  echo "AVISO: $_env_tf não encontrado"
fi

# --- Valores vindos do cluster ----------------------------------------------
export NLB=""
_env_host="$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[[ -n "$_env_host" ]] && export NLB="http://$_env_host"

export MASTER_KEY="$(kubectl get secret auth-service-secret -n "$_env_ns" \
  -o jsonpath='{.data.MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"

# --- Conferência ------------------------------------------------------------
echo
printf "  %-11s %s\n" "VARIÁVEL" "VALOR"
printf "  %-11s %s\n" "--------" "-----"
for v in CLUSTER ECR QUEUE TABLE REDIS NLB MASTER_KEY; do
  val="${!v}"
  if [[ -z "$val" ]]; then
    printf "  \033[1;31m%-11s VAZIA\033[0m\n" "$v"
    _env_falhas=$((_env_falhas + 1))
  elif [[ "$v" == "MASTER_KEY" ]]; then
    # Não imprime a chave inteira no terminal.
    printf "  %-11s %s… (%d caracteres)\n" "$v" "${val:0:8}" "${#val}"
  else
    printf "  %-11s %s\n" "$v" "$val"
  fi
done

# --- Diagnóstico das variáveis vazias ---------------------------------------
if (( _env_falhas > 0 )); then
  echo
  echo "Variáveis vazias e o motivo provável:"
  [[ -z "$CLUSTER" ]] && echo "  CLUSTER/ECR/QUEUE/... → o módulo infra não foi aplicado:"
  [[ -z "$CLUSTER" ]] && echo "      cd \$INFRA/terraform/infra && terraform apply"
  if [[ -n "$CLUSTER" && -z "$NLB" ]]; then
    echo "  NLB → o Load Balancer ainda não foi provisionado. Ou o cluster-addons"
    echo "        não foi aplicado, ou o NLB leva 2-3 min para responder:"
    echo "      kubectl get svc -n ingress-nginx ingress-nginx-controller"
  fi
  if [[ -n "$CLUSTER" && -z "$MASTER_KEY" ]]; then
    echo "  MASTER_KEY → o deploy.sh ainda não rodou nesta sessão:"
    echo "      cd \$INFRA/k8s && ./deploy.sh v1"
  fi
  echo
  echo "Se o kubectl também estiver falhando, reconecte no cluster:"
  echo "      aws eks update-kubeconfig --name \$CLUSTER --region us-east-1"
else
  echo
  echo "Tudo pronto. Comandos das seções 5 e 6 do README já funcionam neste terminal."
fi

unset _env_infra _env_tf _env_ns _env_falhas _env_host
