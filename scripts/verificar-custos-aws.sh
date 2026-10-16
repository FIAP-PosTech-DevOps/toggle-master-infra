#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Procura recursos que geram custo na AWS depois de um destroy.
#
# Uso:
#   ./scripts/verificar-custos-aws.sh                 # us-east-2 e us-east-1
#   ./scripts/verificar-custos-aws.sh us-east-1       # só uma região
#   ./scripts/verificar-custos-aws.sh --custo         # + gasto dos últimos 7 dias
#                                                     #   (Cost Explorer: US$ 0,01 por consulta)
#
# Resultado: "ok" = nada encontrado; "ATENÇÃO" = recurso cobrável listado.
# Código de saída: 0 sem pendências, 1 com pendências, 2 erro de credencial.
#
# Ficam de propósito (stack global): repositórios ECR, a chave KMS do ECR
# (US$ 1/mês), o bucket S3 do state, roles/OIDC do GitHub e o Budget. Aparecem
# só como informação no final.
# -----------------------------------------------------------------------------
set -uo pipefail

CUSTO=false
REGIONS=()
for a in "$@"; do
  case "$a" in
    --custo) CUSTO=true ;;
    -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) REGIONS+=("$a") ;;
  esac
done
[[ ${#REGIONS[@]} -gt 0 ]] || REGIONS=(us-east-2 us-east-1)

command -v aws >/dev/null || { echo "aws cli não encontrado"; exit 2; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || { echo "credenciais AWS inválidas ou expiradas (aws sts get-caller-identity falhou)"; exit 2; }

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else R='' G='' Y='' B='' N=''; fi
ALERTAS=0
ERROS=0
KMS_ESPERADA=""

# report <rótulo> <saída>: imprime ok ou a lista do que sobrou.
# pad <texto>: completa até 26 caracteres (printf conta bytes e desalinha acentos).
pad() { printf '%s%*s' "$1" $((26 - ${#1})) ''; }

report() {
  local label="$1" out
  out="$(sed '/^None$/d;/^[[:space:]]*$/d' <<<"$2" | tr '\t' ' ')"
  if [[ -z "$out" ]]; then
    printf '  %s%s ok%s\n' "$G" "$(pad "$label")" "$N"
  else
    ALERTAS=$((ALERTAS + 1))
    printf '  %s%s ATENÇÃO (%d)%s\n' "$R" "$(pad "$label")" "$(wc -l <<<"$out")" "$N"
    sed 's/^/      - /' <<<"$out"
  fi
}

# check <rótulo> <região> <comando aws com --query>
check() {
  local label="$1" region="$2" out; shift 2
  if ! out="$("$@" --region "$region" --output text 2>&1)"; then
    ERROS=$((ERROS + 1))
    printf '  %s%s ERRO%s %s\n' "$Y" "$(pad "$label")" "$N" "$(head -1 <<<"$out")"
    return
  fi
  report "$label" "$out"
}

# Chaves KMS do cliente ativas (US$ 1/mês cada). As "PendingDeletion" não entram.
check_kms() {
  local region="$1" ids out=""
  if ! ids="$(aws kms list-keys --region "$region" --query 'Keys[].KeyId' --output text 2>&1)"; then
    ERROS=$((ERROS + 1)); printf '  %s%s ERRO%s %s\n' "$Y" "$(pad "KMS (chaves ativas)")" "$N" "$(head -1 <<<"$ids")"; return
  fi
  local manager state id desc
  for k in $ids; do
    IFS=$'\t' read -r manager state id desc < <(aws kms describe-key --region "$region" --key-id "$k" \
      --query 'KeyMetadata.[KeyManager,KeyState,KeyId,Description]' --output text 2>/dev/null)
    [[ "$manager" == CUSTOMER && "$state" == Enabled ]] || continue
    # A chave do ECR (stack global) fica de propósito: vai para "Esperado".
    if [[ "$desc" == *"imagens no ECR"* ]]; then
      KMS_ESPERADA+="  KMS: $id ($region, $desc) — US\$ 1/mês"$'\n'
    else
      out+="$id $desc"$'\n'
    fi
  done
  report "KMS (chaves ativas)" "$out"
}

echo "${B}Conta $ACCOUNT — $(date '+%d/%m/%Y %H:%M')${N}"

for R_ in "${REGIONS[@]}"; do
  echo
  echo "${B}================ $R_ ================${N}"
  echo "Computação e rede"
  check "EKS (clusters)"            "$R_" aws eks list-clusters --query 'clusters[].[@]'
  check "EC2 (instâncias)"          "$R_" aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]'
  check "NAT Gateway"               "$R_" aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].[NatGatewayId]'
  check "Elastic IP"                "$R_" aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AllocationId]'
  check "Load Balancer (ALB/NLB)"   "$R_" aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,Type]'
  check "Load Balancer (clássico)"  "$R_" aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].[LoadBalancerName]'
  check "VPC Endpoint (interface)"  "$R_" aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[?VpcEndpointType==`Interface`].[VpcEndpointId,ServiceName]'
  check "VPC (não default)"         "$R_" aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].[VpcId,CidrBlock]'
  echo "Armazenamento"
  check "EBS (volumes)"             "$R_" aws ec2 describe-volumes --query 'Volumes[].[VolumeId,Size,State]'
  check "EBS (snapshots)"           "$R_" aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize]'
  echo "Bancos e filas"
  check "RDS (instâncias)"          "$R_" aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]'
  check "RDS (clusters Aurora)"     "$R_" aws rds describe-db-clusters --query 'DBClusters[].[DBClusterIdentifier]'
  check "RDS (snapshots manuais)"   "$R_" aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].[DBSnapshotIdentifier]'
  check "ElastiCache (Redis)"       "$R_" aws elasticache describe-cache-clusters --query 'CacheClusters[].[CacheClusterId,CacheNodeType]'
  check "DynamoDB (tabelas)"        "$R_" aws dynamodb list-tables --query 'TableNames[].[@]'
  check "SQS (filas)"               "$R_" aws sqs list-queues --query 'QueueUrls[].[@]'
  echo "Segurança e logs"
  check "Secrets Manager"           "$R_" aws secretsmanager list-secrets --query 'SecretList[].[Name]'
  check_kms "$R_"
  check "CloudWatch Logs"           "$R_" aws logs describe-log-groups --query "logGroups[?contains(logGroupName,'togglemaster') || starts_with(logGroupName,'/aws/eks')].[logGroupName]"
done

echo
echo "${B}Esperado (stack global, fica de propósito)${N}"
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName' --output text 2>/dev/null \
  | tr '\t' '\n' | sed '/^$/d' | wc -l | xargs printf '  ECR: %s repositórios (us-east-1)\n'
aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d;s/^/  S3: /'
printf '%s' "$KMS_ESPERADA"

if $CUSTO; then
  echo
  echo "${B}Gasto dos últimos 7 dias, em UTC (Cost Explorer; o último dia pode estar incompleto)${N}"
  # Separado por tipo: "uso" é o que os recursos custaram; "créditos" é o que
  # a AWS abateu (créditos promocionais). O total líquido sozinho esconde o uso
  # quando há crédito na conta, porque fica perto de zero.
  START="$(date -u -d '7 days ago' +%F)"; END="$(date -u -d 'tomorrow' +%F)"
  printf '  %-10s  %10s  %10s\n' "dia" "uso" "créditos"
  aws ce get-cost-and-usage --time-period "Start=$START,End=$END" --granularity DAILY \
      --metrics UnblendedCost --group-by Type=DIMENSION,Key=RECORD_TYPE \
      --query 'ResultsByTime[].[TimePeriod.Start, Groups[?Keys[0]==`Usage`].Metrics.UnblendedCost.Amount | [0], Groups[?Keys[0]==`Credit`].Metrics.UnblendedCost.Amount | [0]]' \
      --output text 2>&1 \
    | LC_ALL=C awk -F'\t' '
        NF==3 { u=($2=="None")?0:$2; c=($3=="None")?0:$3; tu+=u; tc+=c
                printf "  %-10s  US$ %6.2f  US$ %6.2f\n",$1,u,c; next }
        { print "  "$0 }
        END { if (NR) printf "  %-10s  US$ %6.2f  US$ %6.2f\n","total",tu,tc }' 
fi

echo
if (( ALERTAS == 0 && ERROS == 0 )); then
  echo "${G}${B}Nada cobrável encontrado nas regiões ${REGIONS[*]}.${N}"
  exit 0
fi
(( ALERTAS > 0 )) && echo "${R}${B}$ALERTAS tipo(s) de recurso ainda existem: confira a lista acima antes de apagar qualquer coisa.${N}"
(( ERROS > 0 ))   && echo "${Y}${B}$ERROS verificação(ões) com erro (permissão ou serviço indisponível): resultado incompleto.${N}"
exit 1
