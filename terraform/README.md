# Terraform — ToggleMaster (Fase 3)

Toda a infraestrutura AWS do ToggleMaster em código, com um state remoto por ambiente e três ambientes (develop, staging e production), cada um em uma região.

```
terraform/
├── tf.sh                 wrapper: escolhe backend, tfvars e ambiente
├── .checkov.yaml         achados de segurança aceitos, com motivo
├── bootstrap/            bucket S3 do state (state local, 1x por conta)
├── global/               recursos da conta: ECR, OIDC do GitHub, orçamento
├── modules/              módulos próprios, reutilizados pelos 3 ambientes
│   ├── network/          VPC, sub-redes públicas/privadas, IGW, NAT, rotas
│   ├── eks/              cluster, node group, access entries, driver EBS
│   ├── data/             3x RDS PostgreSQL, ElastiCache Redis, DynamoDB
│   ├── messaging/        fila SQS + DLQ
│   └── workload-identity/ roles IRSA (ALB, evaluation, analytics, KEDA, OpenBao)
├── infra/                1 ambiente = composição dos módulos
│   └── envs/             develop | staging | production (.tfvars + .s3.tfbackend)
└── cluster-addons/       o que roda dentro do cluster (Helm)
    └── envs/             develop | staging | production
```

## Pré-requisitos

| Ferramenta | Versão | Usada em |
|---|---|---|
| Terraform | **1.10 ou mais nova** (a CI e o teste local usam a série 1.16) | todos os stacks. O lock nativo no S3 (`use_lockfile`) não existe antes da 1.10, e o `init` falha com `Unsupported Terraform Core version` |
| AWS CLI | v2 | `tf.sh` (descobre o account ID) e scripts |
| kubectl | compatível com o EKS 1.36 | acesso ao cluster e `openbao-bootstrap.sh` |
| Docker | qualquer | `mirror-images.sh` |
| jq, openssl, python3 | qualquer | `openbao-bootstrap.sh` |

As credenciais AWS precisam ser de um **usuário ou role IAM**, nunca do root: o EKS não aceita o root como admin do cluster (`cluster_admin_principal_arns` só aceita `:user/` ou `:role/`).

## Ordem de execução

Os comandos rodam a partir de `terraform/`.

| # | Comando | Frequência | O que cria |
|---|---|---|---|
| 1 | `./tf.sh bootstrap apply` | 1x por conta | bucket `togglemaster-tfstate-<account_id>` |
| 2 | `./tf.sh global apply` | 1x por conta | ECR (5 serviços + espelhos), pull-through cache, OIDC do GitHub + 3 roles, orçamento |
| 3 | `../scripts/mirror-images.sh` | 1x por conta | imagens do KEDA e imagens base no ECR |
| 4 | `./tf.sh infra <ambiente> apply` | por ambiente | VPC, EKS, RDS, Redis, DynamoDB, SQS, IRSA |
| 5 | `./tf.sh cluster-addons <ambiente> apply` | por ambiente | metrics-server, ALB controller, ingress-nginx, KEDA, ArgoCD, OpenBao, External Secrets |
| 6 | `../scripts/openbao-bootstrap.sh <ambiente>` | por ambiente | inicializa o OpenBao e grava os segredos da aplicação |
| 7 | `../scripts/argocd-repo-credentials.sh <ambiente>` | por ambiente, **só se o repo GitOps for privado** | credencial de leitura do `toggle-master-gitops` no ArgoCD |

Depois do passo 5, o ArgoCD passa a sincronizar sozinho o repositório [`toggle-master-gitops`](https://github.com/FIAP-PosTech-DevOps/toggle-master-gitops) (pasta `clusters/<ambiente>`). Antes do primeiro ambiente, rode lá o `scripts/set-aws-account.sh` para trocar o account ID dos manifestos.

Os passos 4 a 7 podem rodar para os três ambientes em paralelo, em terminais separados: cada um tem seu state, sua região e seus nomes. A pipeline (`terraform.yml`) automatiza os passos 4 a 6; os passos 1 a 3 são da conta e ficam manuais de propósito, porque criam o bucket e as roles que a própria pipeline usa.

### Antes do `global` (conta reaproveitada)

Se a conta já foi usada em outra fase do projeto, confira se sobrou algo com o mesmo nome. O `apply` falha com `RepositoryAlreadyExistsException` ou `EntityAlreadyExists` se encontrar:

```bash
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName' --output table
aws ecr describe-pull-through-cache-rules --region us-east-1 --query 'pullThroughCacheRules[].ecrRepositoryPrefix'
aws iam list-open-id-connect-providers
aws iam list-roles --query "Roles[?starts_with(RoleName,'togglemaster')].RoleName"
```

Repositórios `mirror/*`, `k8s/*` e `ecr-public/*` antigos podem ser apagados sem perda: o `mirror-images.sh` e o pull-through cache os recriam. Importar não resolve, porque os novos são criptografados com a chave KMS do projeto e a criptografia de um repositório não muda sem recriá-lo.

```bash
aws ecr delete-repository --region us-east-1 --repository-name <nome> --force
```

### Depois do `global`: confirmar o e-mail do orçamento

Desde 30/09/2026 o AWS Budgets exige que cada e-mail novo seja verificado. A AWS manda um e-mail "Verify ... for AWS accountId" (remetente `@aws.com`); sem a confirmação, os alertas de 50%, 80% e 100% não chegam. O link vale 12 horas e só pode ser usado uma vez. Se expirar, reenvie em **AWS User Notifications → Email contacts**.

### Antes do primeiro `infra apply`: quem administra o cluster

Sem ao menos um ARN em `cluster_admin_principal_arns`, o plan falha com uma mensagem explicativa: só as roles do GitHub Actions teriam `kubectl` no cluster.

- **Para a pipeline**, o ARN precisa estar versionado em `infra/envs/<ambiente>.tfvars`.
- **Para um teste local**, sem mexer em arquivo versionado, use um `*.auto.tfvars` (está no `.gitignore` e vale para os 3 ambientes):

```bash
echo "cluster_admin_principal_arns = [\"$(aws sts get-caller-identity --query Arn --output text)\"]" > infra/admin.auto.tfvars
```

### Acessar o cluster

```bash
aws eks update-kubeconfig --region us-east-2 \
  --name "$(./tf.sh infra develop output -raw cluster_name)" --alias togglemaster-develop
kubectl get nodes
```

O alias `togglemaster-<ambiente>` é o mesmo que o `openbao-bootstrap.sh` usa. Troque a região conforme o ambiente (tabela abaixo).

### Conferir um ambiente recém-criado

```bash
kubectl get pods -A                          # addons Running
kubectl -n argocd get applications           # root e platform Healthy
kubectl get externalsecrets -A               # SecretSynced, depois do openbao-bootstrap
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo     # URL pública (NLB)
```

Até a CI publicar a primeira imagem de cada serviço, os overlays do GitOps apontam para `v0.0.0`: as 5 Applications ficam `Degraded`/`OutOfSync` com `ImagePullBackOff`. É esperado.

Interface do ArgoCD (deixe o port-forward aberto num terminal separado; se ele cair, o login falha com "Request has been terminated"):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward -n argocd svc/argocd-server 8080:80     # http://localhost:8080, usuário admin
```

## Destruir um ambiente

Na ordem inversa, conferindo entre os passos:

```bash
# 1. addons: remove o NLB do ingress-nginx e o volume EBS do OpenBao
./tf.sh cluster-addons develop destroy

# 2. nada criado de dentro do cluster pode ter ficado para trás (as duas saídas devem ser [])
aws elbv2 describe-load-balancers --region us-east-2 --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-volumes --region us-east-2 --filters Name=status,Values=available --query 'Volumes[].VolumeId'

# 3. infra
./tf.sh infra develop destroy

# 4. segredo criado pelo openbao-bootstrap (fora do Terraform; cobra US$0,40/mês)
aws secretsmanager delete-secret --region us-east-2 \
  --secret-id togglemaster/develop/openbao-init --force-delete-without-recovery
```

Se o passo 2 mostrar um load balancer, apague-o antes do passo 3; senão o destroy da VPC falha com `DependencyViolation`.

Pela pipeline (**Actions → terraform → Run workflow**, ação `destroy`), os quatro passos rodam em sequência: o job espera os load balancers saírem da VPC antes do destroy da infra e apaga o segredo do OpenBao no final.

Verificação final (todas as saídas vazias):

```bash
R=us-east-2
aws eks list-clusters --region $R
aws rds describe-db-instances --region $R --query 'DBInstances[].DBInstanceIdentifier'
aws elasticache describe-replication-groups --region $R --query 'ReplicationGroups[].ReplicationGroupId'
aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-addresses --region $R --query 'Addresses[].PublicIp'
```

O `global` e o `bootstrap` ficam: o ECR com as imagens e o bucket com o histórico dos states são compartilhados pelos ambientes e custam centavos. As chaves KMS do ambiente ficam 7 dias em `PendingDeletion`, sem custo.

## Ambientes

| Ambiente | Região | VPC | Recebe deploy de |
|---|---|---|---|
| develop | us-east-2 (Ohio) | 10.10.0.0/16 | push em `release/vX.Y.Z` |
| staging | us-west-2 (Oregon) | 10.20.0.0/16 | tag `vX.Y.Z-rc.N` |
| production | us-east-1 (N. Virginia) | 10.30.0.0/16 | tag `vX.Y.Z` (aprovação + janela do ArgoCD) |

O código é o mesmo para os três. O que muda fica em `envs/<ambiente>.tfvars`: região, AZs, CIDRs, tamanho e as proteções de produção (comentadas em `production.tfvars` por causa do custo).

Cada ambiente ligado custa cerca de **US$0,40/hora** (EKS, 2 nós, NAT, 3 RDS, Redis e NLB). O orçamento do stack `global` vale para a conta inteira, somando os três.

## State remoto, lock e versionamento

**Backend S3 com lock nativo.** Todos os stacks, exceto o `bootstrap`, usam `backend "s3"` com `use_lockfile = true`. Durante um `plan`/`apply` o Terraform grava `<key>.tflock` no próprio bucket; uma segunda execução no mesmo ambiente espera ou falha, em vez de corromper o state. A tabela DynamoDB de lock ficou obsoleta no Terraform 1.11, então não é usada.

**Um state por ambiente e por stack.** As keys são `global/`, `infra/<ambiente>/` e `cluster-addons/<ambiente>/`. Um `apply` em develop não consegue tocar o state de production.

**Versionamento em vez de cópia de backup.** Em vez de copiar o `tfstate` para um arquivo de backup a cada execução, o bucket tem versionamento ligado: cada `apply` gera uma nova versão do objeto. Um state corrompido ou apagado volta pela versão anterior:

```bash
BUCKET=togglemaster-tfstate-$(aws sts get-caller-identity --query Account --output text)
aws s3api list-object-versions --bucket "$BUCKET" --prefix infra/develop/terraform.tfstate \
  --query 'Versions[].{id:VersionId,data:LastModified}' --output table
aws s3api get-object --bucket "$BUCKET" --key infra/develop/terraform.tfstate \
  --version-id <id> terraform.tfstate.restaurado
```

As versões antigas ficam 90 dias (as 30 mais recentes nunca expiram). O bucket tem `prevent_destroy`, criptografia KMS, bloqueio de acesso público e recusa conexões sem TLS.

**Por que o bootstrap tem state local.** É o ovo e a galinha: o bucket não existe quando o stack que o cria roda pela primeira vez. Como o stack só contém o bucket, recriar esse state é trivial (`terraform import aws_s3_bucket.tfstate <nome>`).

## O `tf.sh`

```bash
./tf.sh infra develop plan
./tf.sh infra develop apply
./tf.sh infra develop output -raw cluster_name
./tf.sh cluster-addons staging plan
```

O script:

1. descobre o bucket pelo account ID, então nenhum arquivo versionado contém o número da conta;
2. usa `envs/<ambiente>.s3.tfbackend` e `envs/<ambiente>.tfvars` do stack;
3. isola o `.terraform` por ambiente (`TF_DATA_DIR`), para que trocar de ambiente nunca reaproveite o backend do anterior.

## GitHub Actions sem chave de acesso

O stack `global` cria o provedor OIDC do GitHub e três roles:

| Role | Quem assume | Permissão |
|---|---|---|
| `togglemaster-gha-ecr-push` | repositórios dos 5 serviços, só em `release/*` e tags `v*` | push nos repositórios `togglemaster/*` do ECR |
| `togglemaster-gha-terraform-plan` | `toggle-master-infra`, qualquer branch ou PR | `ReadOnlyAccess` + lock no bucket de state |
| `togglemaster-gha-terraform-apply` | `toggle-master-infra`, só jobs com `environment:` | `AdministratorAccess` |

Nenhum `AWS_ACCESS_KEY_ID` fica no GitHub. Para ligar a pipeline (`.github/workflows/terraform.yml`):

1. Crie a variável `AWS_ACCOUNT_ID` na **organização** (Settings → Secrets and variables → Actions → Variables), que serve aos 7 repositórios. A visibilidade "Public repositories" basta enquanto os repositórios forem públicos. Sem a variável, o ARN da role sai sem o número da conta e o passo da AWS falha com `Request ARN is invalid`.
2. Em **Settings → Environments** deste repositório, crie `develop`, `staging` e `production`. Em `production`, marque **Required reviewers**: o apply só roda depois de uma aprovação.
3. Versione o ARN de quem administra o cluster em `infra/envs/<ambiente>.tfvars` (ver [Antes do primeiro `infra apply`](#antes-do-primeiro-infra-apply-quem-administra-o-cluster)).

Até o `global` ser aplicado, o job de plan de um PR falha no passo `configure-aws-credentials`: a role ainda não existe. É esperado no primeiro PR.

A estratégia de branches é **release branch + tags**, com a criação da release e as promoções feitas por botão:

```
feature/*, fix/*  --PR-->  release/vX.Y.Z  --push-->  develop
                           tag vX.Y.Z-rc.N  -------->  staging
                           tag vX.Y.Z       -------->  production (mesmo commit do rc aprovado)
                           release/vX.Y.Z  --PR-->  main (depois de production)
```

A `main` só recebe o que já está em produção. Cancelar um pacote é abandonar a release, sem desfazer nada na `main`.

| Evento | O que roda |
|---|---|
| PR para `release/*` | fmt, validate, tflint, checkov e plan de **develop** |
| PR para `main` | o mesmo, com plan de **production** (confere que não há drift) |
| push em `release/*` (com mudança em `terraform/`) | validação + apply em **develop** |
| tag `vX.Y.Z-rc.N` | validação + apply em **staging** |
| tag `vX.Y.Z` | validação + apply em **production**, depois da aprovação do Environment |
| manual (`workflow_dispatch`) | plan, apply ou destroy de qualquer ambiente |

Atenção ao custo: um push numa release (ou uma tag) **cria o ambiente** se ele estiver desligado. Destrua pelo `workflow_dispatch` (ação `destroy`) ao fim da sessão.

## Addons do cluster

| Arquivo | Componente | Por quê |
|---|---|---|
| `metrics-server.tf` | metrics-server | pré-requisito do HPA |
| `alb-controller.tf` | AWS Load Balancer Controller (IRSA) | cria o NLB do ingress |
| `ingress-nginx.tf` | ingress-nginx | roteamento HTTP para os serviços |
| `keda.tf` | KEDA (IRSA) | escala o analytics-service pela fila |
| `storage-class.tf` | StorageClass `gp3` padrão | volumes EBS (usado pelo OpenBao) |
| `argocd.tf` | ArgoCD + Application raiz | GitOps: sincroniza `clusters/<ambiente>` do repositório `toggle-master-gitops` |
| `openbao.tf` | OpenBao (auto-unseal com KMS via IRSA) | cofre dos segredos da aplicação |
| `external-secrets.tf` | External Secrets Operator | entrega os segredos do OpenBao aos pods |

Ferramentas de terceiros entram por Helm; as aplicações próprias ficam no repositório GitOps, com Kustomize.

**Segredos sem arquivo de texto.** DATABASE_URL, MASTER_KEY e SERVICE_API_KEY ficam no OpenBao. O repositório GitOps só declara `ExternalSecret`, uma referência ao caminho do segredo, nunca o valor. O `scripts/openbao-bootstrap.sh` inicializa o cofre e guarda o root token e a recovery key no AWS Secrets Manager (`togglemaster/<ambiente>/openbao-init`). O script é idempotente: rodar de novo não apaga nada.

**Auto-unseal como plugin (OpenBao 2.7+).** A partir da 2.7, o seal `awskms` deixou de ser embutido no binário e virou um plugin do tipo `kms`. O `openbao.tf` declara `plugin "kms" "awskms"`, que o servidor baixa do ghcr.io na subida (`plugin_auto_download`) para um `emptyDir` em `/openbao/plugins`. A imagem do plugin fica na variável `openbao_kms_plugin_image`, **fixada por digest** (a validação recusa tag solta): esse binário roda com acesso à chave de unseal. Para atualizar a versão:

```bash
docker buildx imagetools inspect ghcr.io/openbao/openbao-plugin-kms-aws:<versão> --format '{{json .Manifest}}' | jq -r .digest
```

O StatefulSet do OpenBao usa `updateStrategy: OnDelete`: depois de um `apply` que mude a configuração, recrie o pod para ela valer (`kubectl -n openbao delete pod openbao-0`).

Confira se as versões dos charts continuam compatíveis com o seu Kubernetes:

```bash
cd cluster-addons && ./check-chart-versions.sh 1.36
```

## Decisões

**Módulos próprios em volta dos oficiais.** `modules/network` e `modules/eks` encapsulam `terraform-aws-modules/vpc` e `/eks`: a malha de rotas, o OIDC e os security groups têm detalhes demais para escrever à mão, mas a interface fica nossa, com as escolhas do projeto (tags de descoberta, IMDSv2, access entries).

**Acesso ao cluster declarado, não herdado.** `enable_cluster_creator_admin_permissions = false`, com access entries explícitos para as roles da CI e para os ARNs de `cluster_admin_principal_arns`. Com pessoas e CI aplicando o mesmo state, o "criador" mudaria a cada execução e o módulo recriaria o acesso toda vez.

**Um ECR para os três ambientes.** A CI faz o build uma vez e publica `v1.0.0-<sha>`. Promover para staging ou production é só trocar a tag no GitOps: a imagem que roda em production é, byte a byte, a que foi testada em staging.

**Nomes com o ambiente.** Nomes de IAM são globais na conta. Todo recurso usa o prefixo `togglemaster-<ambiente>`, o que permite ter os três ambientes ligados ao mesmo tempo.

**Achados de segurança aceitos, com motivo.** `.checkov.yaml` lista o que foi aceito por custo (Multi-AZ, Performance Insights) ou risco registrado (Redis sem TLS). Qualquer achado fora da lista reprova o PR.

## Problemas conhecidos

| Sintoma | Causa | Solução |
|---|---|---|
| `Unsupported Terraform Core version` no `init` | Terraform anterior à 1.10 | atualize o Terraform (ver [Pré-requisitos](#pré-requisitos)) e apague os `.terraform/` antigos |
| `RepositoryAlreadyExistsException` no `global` | repositórios ECR de uma fase anterior | ver [Antes do `global`](#antes-do-global-conta-reaproveitada) |
| `Request ARN is invalid` no `configure-aws-credentials` | variável `AWS_ACCOUNT_ID` não cadastrada no GitHub | crie a variável na organização |
| `Could not assume role` / `Not authorized ... AssumeRoleWithWebIdentity` | o `global` ainda não foi aplicado, ou o job roda numa ref que a role não aceita | aplique o `global`; confira a tabela de roles acima |
| alertas do orçamento não chegam | e-mail ainda não verificado | ver [Depois do `global`](#depois-do-global-confirmar-o-e-mail-do-orçamento) |
| KEDA em `ImagePullBackOff` | o `mirror-images.sh` não rodou | rode o passo 3 e espere o próximo restart do pod |
| `openbao-0` em `CrashLoopBackOff` com `unknown wrapper: awskms` | configuração antiga, sem o plugin KMS | aplique o `cluster-addons` atual e apague o pod `openbao-0` |
| `openbao-bootstrap.sh`: "não foi possível consultar o status do OpenBao" | o processo do OpenBao não está de pé | `kubectl -n openbao logs openbao-0 --tail=40` |
| `ExternalSecret` em `SecretSyncedError` | OpenBao ainda não inicializado | rode o `openbao-bootstrap.sh` |
| login no ArgoCD: "Request has been terminated" | o `kubectl port-forward` caiu ou foi encerrado | suba o port-forward de novo e deixe o terminal aberto |
| destroy da `infra` com `DependencyViolation` na VPC | NLB criado pelo cluster ficou órfão | apague o load balancer e rode o destroy de novo |
