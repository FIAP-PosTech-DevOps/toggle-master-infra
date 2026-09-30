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

## Ordem de execução

| # | Comando | Frequência | O que cria |
|---|---|---|---|
| 1 | `./tf.sh bootstrap apply` | 1x por conta | bucket `togglemaster-tfstate-<account_id>` |
| 2 | `./tf.sh global apply` | 1x por conta | ECR (5 serviços + espelhos), pull-through cache, OIDC do GitHub + 3 roles, orçamento |
| 3 | `../scripts/mirror-images.sh` | 1x por conta | imagens do KEDA e imagens base no ECR |
| 4 | `./tf.sh infra <ambiente> apply` | por ambiente | VPC, EKS, RDS, Redis, DynamoDB, SQS, IRSA |
| 5 | `./tf.sh cluster-addons <ambiente> apply` | por ambiente | metrics-server, ALB controller, ingress-nginx, KEDA, ArgoCD, OpenBao, External Secrets |
| 6 | `../scripts/openbao-bootstrap.sh <ambiente>` | por ambiente | inicializa o OpenBao e grava os segredos da aplicação |

Os passos 4 a 6 podem rodar para os três ambientes em paralelo (terminais separados, ou a pipeline): cada um tem seu state, sua região e seus nomes.

Para destruir um ambiente, na ordem inversa:

```bash
./tf.sh cluster-addons develop destroy
./tf.sh infra develop destroy
```

O `global` e o `bootstrap` ficam: o ECR com as imagens e o bucket com o histórico dos states são compartilhados pelos ambientes e custam centavos.

### Antes do primeiro `infra apply`

Coloque o seu usuário IAM em `cluster_admin_principal_arns` no `infra/envs/<ambiente>.tfvars`. O plan falha com uma mensagem explicativa enquanto isso não for feito: sem esse ARN, só as roles do GitHub Actions teriam `kubectl` no cluster.

```bash
aws sts get-caller-identity --query Arn --output text
```

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

1. Em **Settings → Secrets and variables → Actions → Variables**, crie `AWS_ACCOUNT_ID`.
2. Em **Settings → Environments**, crie `develop`, `staging` e `production`. Em `production`, marque **Required reviewers**: o apply só roda depois de uma aprovação.

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

**Segredos sem arquivo de texto.** DATABASE_URL, MASTER_KEY e SERVICE_API_KEY ficam no OpenBao. O repositório GitOps só declara `ExternalSecret`, uma referência ao caminho do segredo, nunca o valor. O `scripts/openbao-bootstrap.sh` inicializa o cofre e guarda o root token e a recovery key no AWS Secrets Manager.

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
