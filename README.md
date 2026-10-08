# ToggleMaster — Infraestrutura

Infraestrutura do ToggleMaster, uma plataforma de feature flags composta por 5 microsserviços. Este repositório cobre:

- **Local**: Docker Compose com LocalStack, para desenvolvimento.
- **AWS**: três ambientes (develop, staging e production), cada um em uma região, com EKS provisionado por Terraform, deploy por GitOps (ArgoCD) e segredos no OpenBao.
- **CI/CD**: os workflows reutilizáveis que os 5 serviços usam (build, testes, SAST, SCA, scan de imagem, ECR e promoção entre ambientes).

| Assunto | Onde está |
|---|---|
| Passo a passo do Terraform, ambientes, destroy e problemas conhecidos | [`terraform/README.md`](terraform/README.md) |
| Pipelines de CI/CD e DevSecOps, configuração do Sonar, Snyk e tokens | [`docs/ci-cd.md`](docs/ci-cd.md) |
| Manifestos das aplicações (Kustomize) e o que o ArgoCD lê | [`toggle-master-gitops`](https://github.com/FIAP-PosTech-DevOps/toggle-master-gitops) |
| Diagrama da Fase 3 (CI/CD, GitOps, ambientes) | [`docs/fase3-cicd-gitops.drawio`](docs/fase3-cicd-gitops.drawio) |
| Fluxo funcional entre os serviços | [`docs/fluxo-geral.md`](docs/fluxo-geral.md) |

## Índice

1. [Arquitetura](#1-arquitetura)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Ambiente local (Docker Compose)](#3-ambiente-local-docker-compose)
4. [Subir um ambiente na AWS](#4-subir-um-ambiente-na-aws)
5. [Testes e validação](#5-testes-e-validação)
6. [Demonstração de escalabilidade](#6-demonstração-de-escalabilidade)
7. [Destruir um ambiente](#7-destruir-um-ambiente)
8. [Custos](#8-custos)
9. [Segurança](#9-segurança)
10. [Estrutura do repositório](#10-estrutura-do-repositório)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Arquitetura

> Diagramas em [`docs/`](docs/), abertos em [app.diagrams.net](https://app.diagrams.net) ou pela extensão Draw.io Integration do VS Code:
> - [`fase3-cicd-gitops.drawio`](docs/fase3-cicd-gitops.drawio): esteira de CI/CD, GitOps, os três ambientes e o fluxo de branches.
> - [`arquitetura.drawio`](docs/arquitetura.drawio): arquitetura AWS de um ambiente, segurança/IRSA e provisionamento (desenhado na Fase 2; a rede e os data stores continuam iguais, mas a pasta `k8s/` e o namespace único foram substituídos pelo GitOps).

| Serviço | Linguagem | Porta | Persistência | Namespace no EKS | Repositório |
|---|---|---|---|---|---|
| auth-service | Go | 8001 | PostgreSQL | `auth-service` | [auth-service](https://github.com/FIAP-PosTech-DevOps/auth-service) |
| flag-service | Python | 8002 | PostgreSQL | `flag-service` | [flag-service](https://github.com/FIAP-PosTech-DevOps/flag-service) |
| targeting-service | Python | 8003 | PostgreSQL | `targeting-service` | [targeting-service](https://github.com/FIAP-PosTech-DevOps/targeting-service) |
| evaluation-service | Go | 8004 | Redis (cache) | `evaluation-service` | [evaluation-service](https://github.com/FIAP-PosTech-DevOps/evaluation-service) |
| analytics-service | Python | 8005 | DynamoDB | `analytics-service` | [analytics-service](https://github.com/FIAP-PosTech-DevOps/analytics-service) |

Cada serviço tem o próprio namespace, com Pod Security `restricted`, a própria ServiceAccount e a própria Application no ArgoCD: o deploy ou o rollback de um não toca os outros.

### Fluxo de uma avaliação

```
cliente → Ingress (NLB) → evaluation-service
                              ├─ Redis (cache, TTL 30s)
                              ├─ flag-service      → PostgreSQL
                              ├─ targeting-service → PostgreSQL
                              └─ SQS → analytics-service → DynamoDB
```

O `evaluation-service` é o caminho quente: responde do Redis sempre que possível e publica o evento na fila de forma assíncrona, sem bloquear a resposta.

### Do commit ao cluster

```
repositório do serviço ──push release/*──▶ CI (testes, Sonar, Snyk, Trivy) ──▶ ECR (imagem vX.Y.Z-<sha>)
                                              │
                                              └─ commit do newTag ──▶ toggle-master-gitops ──▶ ArgoCD do ambiente
```

Ninguém roda `kubectl apply` à mão. A infraestrutura de cada ambiente vem do Terraform deste repositório, e as aplicações vêm do repositório GitOps. Detalhes em [`docs/ci-cd.md`](docs/ci-cd.md).

### Por que três data stores diferentes

| Store | Uso | Motivo |
|---|---|---|
| **RDS PostgreSQL** | definições de flags, regras, chaves de API | dados relacionais, consultados por chave de negócio, com integridade transacional |
| **ElastiCache Redis** | cache do caminho quente | leitura sub-milissegundo; evita bater no banco a cada avaliação |
| **DynamoDB** | eventos de analytics | volume alto de escrita, schema simples por chave, sem relacionamento |

### Equivalência entre os ambientes

| Local (Docker Compose) | AWS (cada ambiente) |
|---|---|
| 3 containers PostgreSQL | 3 instâncias RDS PostgreSQL |
| container Redis | ElastiCache Redis |
| LocalStack (SQS + DynamoDB) | SQS e DynamoDB reais |
| build local das imagens | ECR privado (compartilhado pelos 3 ambientes) |
| `.env` local | OpenBao + External Secrets |
| — | EKS, Ingress/NLB, HPA, KEDA, ArgoCD |

| Ambiente | Região | Recebe deploy de |
|---|---|---|
| develop | us-east-2 (Ohio) | push em `release/vX.Y.Z` |
| staging | us-west-2 (Oregon) | tag `vX.Y.Z-rc.N` |
| production | us-east-1 (N. Virginia) | tag `vX.Y.Z`, com aprovação e janela de deploy |

---

## 2. Pré-requisitos

### 2.1 Estrutura de pastas

O `docker-compose.yml` referencia os serviços por caminho relativo. **Todos os repositórios precisam estar clonados na mesma pasta pai:**

```
ToggleMaster/
├── toggle-master-infra/     ← este repositório
├── toggle-master-gitops/
├── auth-service/
├── flag-service/
├── targeting-service/
├── evaluation-service/
└── analytics-service/
```

```bash
mkdir ToggleMaster && cd ToggleMaster
for r in toggle-master-infra toggle-master-gitops auth-service flag-service targeting-service evaluation-service analytics-service; do
  git clone https://github.com/FIAP-PosTech-DevOps/$r.git $r
done
```

### 2.2 Variável de atalho

Todos os comandos deste README usam `$INFRA` como referência à raiz deste repositório, para funcionarem de qualquer diretório. Defina uma vez por sessão de terminal:

```bash
export INFRA=~/Git/ToggleMaster/toggle-master-infra
```

Ajuste o caminho se você clonou em outro lugar. Para não precisar repetir a cada terminal novo, acrescente a linha ao seu `~/.bashrc`.

### 2.3 Ferramentas

| Ferramenta | Necessária para | Versão mínima |
|---|---|---|
| Docker | ambos os ambientes | — |
| Terraform | AWS | **1.10** (lock nativo do state no S3) |
| AWS CLI | AWS | v2 |
| kubectl | AWS | compatível com o EKS 1.36 |
| jq, python3, openssl | scripts (`openbao-bootstrap.sh`, testes) | — |
| helm | opcional: só para depurar valores de chart | 3.x |

> Rode um bloco de cada vez, não tudo de uma vez. O `newgrp docker` no final da etapa 1 substitui o shell atual e atrapalharia os comandos seguintes.

**Ubuntu/Debian — 1. Docker Engine + Compose**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg unzip

# Chave GPG oficial do Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Repositório oficial. UBUNTU_CODENAME não existe em Debian/Mint — o
# fallback para VERSION_CODENAME cobre esses casos.
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Permite usar o docker sem sudo
sudo usermod -aG docker $USER
newgrp docker      # ou faça logout/login
```

**2. Terraform**

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
terraform version     # precisa ser 1.10 ou mais nova
```

Se o Terraform já estiver instalado fora do apt (por exemplo em `~/.local/bin`, confira com `which terraform`), troque o binário pela versão nova baixada de [releases.hashicorp.com/terraform](https://releases.hashicorp.com/terraform/), ou use o [tfenv](https://github.com/tfutils/tfenv) para alternar versões.

**3. AWS CLI v2**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
rm -rf awscliv2.zip aws/
```

**4. kubectl**

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
```

**5. Helm (opcional)**

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**6. Utilitários usados pelos scripts**

```bash
sudo apt install -y jq python3 openssl
```

**macOS**

```bash
brew install --cask docker
brew install terraform awscli kubernetes-cli helm jq openssl
```

> **`eksctl` não é necessário.** Ele era usado no provisionamento manual para associar o provedor OIDC ao cluster. Com Terraform, o módulo EKS faz isso sozinho via `enable_irsa = true`.

### Validar a instalação

```bash
docker --version
docker compose version
terraform version
aws --version
kubectl version --client
helm version
jq --version && python3 --version && openssl version
```

### 2.4 Credenciais AWS

Não use as chaves do usuário root.

1. Console AWS → **IAM → Users → Create user**, nome `terraform-admin`
2. **Attach policies directly** → `AdministratorAccess`
   *O Terraform precisa criar roles IAM, VPC, EKS e RDS. O privilégio mínimo do projeto está nas roles que o Terraform **cria** (nós e pods), não em quem aplica.*
3. **Security credentials → Create access key → Command Line Interface (CLI)**
4. Ative MFA nesse usuário

```bash
aws configure
# Access Key ID / Secret Access Key / us-east-1 / json

aws sts get-caller-identity   # deve retornar Account e o ARN do terraform-admin
```

As credenciais ficam em `~/.aws/credentials`. O Terraform lê esse arquivo sozinho — **nunca** coloque chaves em `.tf` ou `.tfvars`.

### 2.5 Liberar o acesso do IAM ao billing

Necessário para o Terraform criar o alarme de orçamento. Só o **usuário root** consegue ativar:

Console como root → **Account → Account settings → IAM user and role access to billing information → Edit → Activate**

Sem isso, o `apply` falha em `aws_budgets_budget` com `AccessDenied`, mesmo com `AdministratorAccess`.

### 2.6 Configuração do Terraform

Os valores que mudam por pessoa ficam fora do Git:

```bash
cd $INFRA/terraform
cp global/terraform.tfvars.example global/terraform.tfvars    # alert_email: recebe os alertas do orçamento
```

O que muda por ambiente fica em `infra/envs/<ambiente>.tfvars` (região, AZs, CIDRs, tamanho, proteções de produção) e é versionado. A única coisa obrigatória ali é quem administra o cluster, `cluster_admin_principal_arns`:

```bash
aws sts get-caller-identity --query Arn --output text    # precisa ser :user/ ou :role/, nunca o root
```

Para a pipeline, o ARN fica versionado nos tfvars. Para um teste local sem mexer em arquivo versionado, use `infra/admin.auto.tfvars` (está no `.gitignore`). Detalhes em [`terraform/README.md`](terraform/README.md#antes-do-primeiro-infra-apply-quem-administra-o-cluster).

- **Versão do EKS** (`cluster_version`, padrão `1.36`): confira as versões em standard support com `aws eks describe-cluster-versions --output table`. Uma versão em *extended support* custa **US$0,60/hora** em vez de US$0,10, seis vezes mais.

> Contas criadas a partir de 15/07/2025 entram no *free plan* e só conseguem lançar `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large` e `m7i-flex.large`. O default do projeto é `c7i-flex.large`. Confirme a sua lista com `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType' --output text`.

### 2.7 Restringir o endpoint do cluster ao seu IP (opcional)

Por padrão o endpoint público do EKS aceita qualquer origem (`0.0.0.0/0`), porque os runners do GitHub Actions também precisam alcançá-lo para aplicar o `cluster-addons`. A autenticação continua exigindo IAM. Para restringir a um IP:

```hcl
# infra/envs/<ambiente>.tfvars
cluster_endpoint_public_access_cidrs = ["SEU.IP.PUBLICO/32"]    # curl -s checkip.amazonaws.com
```

Com a restrição, a pipeline deixa de alcançar o cluster (exigiria runner self-hosted), e o `kubectl` para de responder quando o seu IP muda. O tipo do erro identifica a causa:

| Erro do kubectl | Causa |
|---|---|
| `i/o timeout` | **seu IP não está na allowlist** |
| `no such host` | o cluster não existe (foi destruído) |
| `connection refused` em `localhost:8080` | kubeconfig sem contexto ativo |

Para atualizar o IP, ajuste o tfvars e rode `./tf.sh infra <ambiente> apply` (1 a 2 minutos, só muda a configuração do endpoint). Para conferir o que a AWS aplicou, sem depender do `kubectl`:

```bash
aws eks describe-cluster --name togglemaster-develop-cluster --region us-east-2 \
  --query 'cluster.resourcesVpcConfig.[endpointPublicAccess,publicAccessCidrs]'
```

---

## 3. Ambiente local (Docker Compose)

### 3.1 Construir

Um comando, do zero:

```bash
cd $INFRA
./local-bootstrap.sh
```

Ele faz tudo:

1. Cria o `.env` a partir do `.env.example`, se não existir
2. Gera `MASTER_KEY` e `POSTGRES_PASSWORD` aleatórias
3. Sobe os 10 containers (5 microsserviços, 3 PostgreSQL, Redis, LocalStack)
4. Espera o auth-service responder
5. Cria a `SERVICE_API_KEY` via `POST /admin/keys` e grava no `.env`
6. Recria o `evaluation-service` para carregá-la

**É idempotente.** Rodar de novo preserva as credenciais já geradas e apenas renova a `SERVICE_API_KEY`. Use `--reset-keys` se quiser regenerar tudo.

| Opção | Efeito |
|---|---|
| `--skip-up` | não sobe os containers (assume que já estão no ar) |
| `--reset-keys` | regenera também `MASTER_KEY` e `POSTGRES_PASSWORD` |
| `--help` | mostra o resumo |

**Por que a `SERVICE_API_KEY` precisa desse passo.** O auth-service guarda apenas o **hash SHA-256** da chave (`auth-service/key.go`). Hash é via única: não dá para inventar uma chave e esperar que valide — ela precisa ser criada por `POST /admin/keys` para que exista a linha correspondente na tabela `api_keys`. Como o `init.sql` só cria a tabela, sem inserir nada, um banco novo nasce sem chave alguma. Foi por isso que a chave antiga, fixa no `docker-compose.yml`, quebrava a cada `down -v`.

### 3.2 As credenciais

Nenhuma fica no `docker-compose.yml`. Todas vêm do `.env`, que **não é versionado** — cada pessoa do time tem o seu.

| Variável | Obrigatória | Para quê |
|---|---|---|
| `POSTGRES_USER` | não (padrão `postgres`) | usuário dos 3 bancos locais |
| `POSTGRES_PASSWORD` | **sim** | senha dos 3 bancos locais |
| `MASTER_KEY` | **sim** | protege `POST /admin/keys`, que cria credenciais |
| `SERVICE_API_KEY` | preenchida pelo script | usada pelo evaluation-service para chamar flag e targeting |

O compose usa `${VAR:?mensagem}` nas obrigatórias, então falha com erro claro se faltar alguma, em vez de subir o serviço com valor vazio e quebrar só na primeira requisição.

Confirme que o git está ignorando o arquivo:

```bash
git check-ignore -v .env      # deve responder ".gitignore:2:.env"
git status --short            # o .env NÃO pode aparecer
```

Se o `.env` aparecer no `git status`, algo está errado no `.gitignore` — não commite.

**Comandos do Compose exigem o `.env`.** O Compose interpola o arquivo antes de executar qualquer subcomando — então `docker compose down`, `ps` ou `logs` também falham se o `.env` não existir. A mensagem aponta a solução:

```
required variable POSTGRES_PASSWORD is missing a value: rode ./local-bootstrap.sh
```

**Subir sem o script**, se preferir controlar cada passo:

```bash
cp .env.example .env
# edite MASTER_KEY e POSTGRES_PASSWORD
docker compose up -d
./local-bootstrap.sh --skip-up   # só a parte da SERVICE_API_KEY
```

### 3.3 Portas

| Serviço | Porta |
|---|---|
| auth-service | 8001 |
| flag-service | 8002 |
| targeting-service | 8003 |
| evaluation-service | 8004 |
| analytics-service | 8005 |
| postgres-auth | 5431 |
| postgres-flag | 5432 |
| postgres-targeting | 5433 |
| redis | 6379 |
| localstack | 4566 |

### 3.4 Testar

```bash
for p in 8001 8002 8003 8004 8005; do
  echo -n "porta $p: "; curl -s localhost:$p/health; echo
done
```

Criar a fila e a tabela no LocalStack (necessário uma vez por sessão):

```bash
aws --endpoint-url=http://localhost:4566 --region us-east-1 \
  sqs create-queue --queue-name togglemaster-queue

aws --endpoint-url=http://localhost:4566 --region us-east-1 \
  dynamodb create-table --table-name ToggleMasterAnalytics \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

O fluxo funcional é o mesmo da [seção 5.2](#52-validação-funcional-dos-endpoints), trocando a URL do NLB por `http://localhost:8001` (auth), `:8002` (flags), `:8003` (rules) e `:8004` (evaluate).

### 3.5 Destruir

```bash
docker compose stop        # para os containers, preservando os dados
docker compose down        # remove os containers — OS BANCOS SÃO PERDIDOS
```

**Atenção:** este compose **não declara volumes nomeados** para o PostgreSQL. Os dados ficam na camada de escrita do próprio container, então `docker compose down` — mesmo sem `-v` — zera os três bancos. O `-v` não muda nada aqui, porque não há volume de dados para remover.

Consequência prática: qualquer `down` invalida a `SERVICE_API_KEY`, porque a tabela `api_keys` some junto. Para voltar:

```bash
./local-bootstrap.sh       # detecta e regenera
```

Se quiser preservar os dados entre sessões, use `docker compose stop` / `docker compose start` em vez de `down` / `up`.

---

## 4. Subir um ambiente na AWS

O passo a passo completo, com o que conferir em cada etapa, está em [`terraform/README.md`](terraform/README.md). O resumo:

```bash
cd $INFRA/terraform

# 1 vez por conta (fica ligado; custa centavos por mês)
./tf.sh bootstrap apply              # bucket do state
./tf.sh global apply                 # ECR, OIDC do GitHub, roles da CI, orçamento
../scripts/mirror-images.sh          # imagens de terceiros no ECR (precisa do Docker)

# por ambiente (develop | staging | production), ~35 min
./tf.sh infra develop apply              # VPC, EKS, RDS, Redis, DynamoDB, SQS, IRSA (~20-25 min)
./tf.sh cluster-addons develop apply     # ALB controller, ingress-nginx, KEDA, ArgoCD, OpenBao, ESO (~5-10 min)
../scripts/openbao-bootstrap.sh develop  # inicializa o OpenBao e grava os segredos
```

Depois disso o ArgoCD do ambiente sincroniza sozinho o repositório [`toggle-master-gitops`](https://github.com/FIAP-PosTech-DevOps/toggle-master-gitops). As aplicações sobem com a imagem que estiver no overlay do ambiente; até a CI publicar a primeira versão de cada serviço, elas ficam em `ImagePullBackOff` (overlay em `v0.0.0`).

**Pela pipeline.** Depois do setup da conta, um ambiente inteiro (infra, addons e `openbao-bootstrap`) também sobe pelo GitHub Actions (`terraform.yml`): push numa `release/*` aplica em develop, a tag `-rc` em staging e a tag final em production. Para subir ou destruir sob demanda, use **Actions → terraform → Run workflow**, escolhendo o ambiente e a ação.

**Deploy das aplicações.** Não há mais script de deploy. Uma versão chega a um ambiente quando a CI do serviço altera o `newTag` no repositório GitOps (ver [`docs/ci-cd.md`](docs/ci-cd.md)). Para voltar uma versão, faça `git revert` do commit de deploy no repositório GitOps.

Para ver o que está rodando:

```bash
kubectl -n argocd get applications
kubectl get deploy -A -l app.kubernetes.io/part-of=togglemaster \
  -o custom-columns='NAMESPACE:.metadata.namespace,IMAGEM:.spec.template.spec.containers[0].image'
```

---

## 5. Testes e validação

### 5.0 Variáveis da sessão

Os comandos das seções 5 e 6 usam variáveis que **mudam a cada ciclo**: a AWS gera sufixos aleatórios nos endpoints, e a `MASTER_KEY` é gerada pelo `openbao-bootstrap.sh` em cada ambiente novo. Carregue-as num terminal:

```bash
cd $INFRA/terraform
AMB=develop
OUT=$(./tf.sh infra $AMB output -json)
export REGION=$(jq -r .aws_region.value          <<<"$OUT")
export CLUSTER=$(jq -r .cluster_name.value       <<<"$OUT")
export ECR=$(jq -r .ecr_registry.value           <<<"$OUT")
export QUEUE=$(jq -r .sqs_queue_url.value        <<<"$OUT")
export TABLE=$(jq -r .dynamodb_table_name.value  <<<"$OUT")
export REDIS=$(jq -r .redis_endpoint.value       <<<"$OUT")

aws eks update-kubeconfig --region $REGION --name $CLUSTER --alias togglemaster-$AMB >/dev/null
export NLB=http://$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export MASTER_KEY=$(kubectl -n auth-service get secret auth-service-secret \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

echo "REGION=$REGION CLUSTER=$CLUSTER NLB=$NLB"
```

Se o `NLB` vier só com `http://`, o load balancer ainda está provisionando (2 a 3 minutos depois do `cluster-addons`). Se a `MASTER_KEY` vier vazia, o `openbao-bootstrap.sh` não rodou ou o ExternalSecret ainda não sincronizou (`kubectl get externalsecrets -A`).

**Repita o bloco a cada terminal novo.** Variável de ambiente existe só no shell onde foi definida.

**Pods de teste nos namespaces dos serviços.** Os namespaces das aplicações têm Pod Security `restricted`, e um `kubectl run` simples é recusado ali. Esta função cria o pod já com o `securityContext` exigido:

```bash
psa_run() {   # uso: psa_run <namespace> <nome> <serviceaccount> <imagem> <args...>
  local ns=$1 name=$2 sa=$3 img=$4; shift 4
  local args; args=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  kubectl run "$name" -n "$ns" --restart=Never --image="$img" --overrides="$(jq -nc \
    --arg n "$name" --arg i "$img" --arg sa "$sa" --argjson a "$args" '{spec:{
      serviceAccountName:$sa,
      securityContext:{runAsNonRoot:true,runAsUser:1000,seccompProfile:{type:"RuntimeDefault"}},
      containers:[{name:$n,image:$i,args:$a,
        securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}}}]}}')"
}
```

Os testes que não precisam de ServiceAccount rodam no namespace `default`, que não tem essa restrição.

### 5.1 Validação da infraestrutura

**Nós e capacidade**

```bash
kubectl get nodes -o wide
```

`STATUS: Ready`, `EXTERNAL-IP: <none>` (prova que estão em sub-rede privada) e kubelet na versão esperada.

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.pods}{" pods\t"}{.status.allocatable.memory}{"\n"}{end}'
```

Com `c7i-flex.large`: ~29 pods e ~3,4 GiB alocáveis por nó.

**Plataforma**

```bash
kubectl -n argocd get applications          # root e platform: Synced/Healthy
kubectl get externalsecrets -A              # SecretSynced / True
kubectl -n openbao get pods                 # openbao-0 Running 1/1 (inicializado e unsealed)
```

**Conectividade com o RDS**: valida security group, subnet group, DNS privado e credenciais de uma vez.

```bash
SENHA=$(aws secretsmanager get-secret-value --region $REGION \
  --secret-id $(jq -r .rds_master_user_secret_arns.value.auth <<<"$OUT") \
  --query SecretString --output text | jq -r .password)
ENDPOINT=$(jq -r .rds_addresses.value.auth <<<"$OUT")

kubectl run pgtest --rm -i --restart=Never \
  --image=$ECR/mirror/library/postgres:15-alpine -- \
  psql "postgres://postgres:$SENHA@$ENDPOINT:5432/auth_db?sslmode=require" -c "select version();"
```

**Conectividade com o Redis**

```bash
kubectl run redistest --rm -i --restart=Never \
  --image=$ECR/mirror/library/redis:7-alpine -- \
  redis-cli -h $REDIS ping     # PONG
```

> As imagens de teste vêm do ECR, como todo o resto. O `aws-cli` usado a seguir vem de `public.ecr.aws` via pull-through cache: o repositório é criado sozinho no primeiro uso.

**IRSA concedendo o permitido**

```bash
psa_run analytics-service irsa-ok analytics-service-sa $ECR/ecr-public/aws-cli/aws-cli \
  sqs get-queue-attributes --region $REGION --queue-url $QUEUE --attribute-names ApproximateNumberOfMessages
sleep 20 && kubectl logs -n analytics-service irsa-ok && kubectl delete pod -n analytics-service irsa-ok
```

**IRSA negando o não permitido**: aqui o resultado correto é `AccessDenied`.

```bash
psa_run analytics-service irsa-deny analytics-service-sa $ECR/ecr-public/aws-cli/aws-cli \
  dynamodb scan --region $REGION --table-name $TABLE
sleep 20 && kubectl logs -n analytics-service irsa-deny && kubectl delete pod -n analytics-service irsa-deny
```

A role do analytics tem apenas `dynamodb:PutItem`. Vale gravar essa tela: prova que a permissão é granular, não um `*`.

**Nenhuma imagem vinda de registro público**

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
```

Quase tudo deve começar com `<conta>.dkr.ecr.us-east-1.amazonaws.com/` (o ECR fica em us-east-1 e serve os três ambientes). As exceções são os addons gerenciados pela AWS (`aws-node`, `kube-proxy`, `coredns`, driver EBS), servidos pelo ECR da própria AWS, e os charts cujas imagens não passam pelo espelho (por exemplo ArgoCD e OpenBao, vindos de `quay.io` e `ghcr.io`).

### 5.2 Validação funcional dos endpoints

Usa `$NLB` e `$MASTER_KEY`, definidos em [5.0](#50-variáveis-da-sessão). A `MASTER_KEY` é lida do Secret criado pelo External Secrets, então não depende de ter guardado nada.

**Rotas expostas pelo Ingress**

| Rota | Serviço | Autenticação |
|---|---|---|
| `POST /admin/keys` | auth-service | `MASTER_KEY` |
| `GET /validate` | auth-service | API key |
| `POST/GET/PUT/DELETE /flags` | flag-service | API key |
| `POST/GET/PUT/DELETE /rules` | targeting-service | API key |
| `GET /evaluate` | evaluation-service | nenhuma |

Cada serviço declara o próprio Ingress no seu namespace, e o ingress-nginx junta todos no mesmo endereço do NLB.

**1. Criar uma chave de API**

```bash
RESP=$(curl -s -X POST "$NLB/admin/keys" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"teste-manual"}')

echo "$RESP"                          # veja a resposta crua antes de parsear
API_KEY=$(echo "$RESP" | jq -r .key)
echo "API_KEY=$API_KEY"
```

Se o `jq` reclamar de `Invalid numeric literal`, a resposta não era JSON: quase sempre `Acesso não autorizado` por `MASTER_KEY` errada, ou uma página de erro do nginx porque o `$NLB` está vazio. O `echo "$RESP"` mostra qual dos dois é.

**2. Criar uma feature flag**

```bash
curl -s -X POST "$NLB/flags" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"name":"novo-checkout","description":"demo","is_enabled":true}' | jq
```

**3. Criar a regra de segmentação**

```bash
curl -s -X POST "$NLB/rules" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"flag_name":"novo-checkout","rules":{"type":"PERCENTAGE","value":50}}' | jq
```

> O `evaluator.go` implementa **apenas** `PERCENTAGE`. O `USER_LIST` aparece como exemplo no `init.sql`, mas ainda não foi implementado: qualquer outro tipo cai no `return false`.

**4. Avaliar**: query parameters, sem autenticação.

```bash
curl -s "$NLB/evaluate?user_id=u1&flag_name=novo-checkout"  | jq   # true
curl -s "$NLB/evaluate?user_id=u2&flag_name=novo-checkout"  | jq   # false
curl -s "$NLB/evaluate?user_id=u10&flag_name=novo-checkout" | jq   # false
```

O resultado é determinístico: `sha1(user_id + flag_name)`, primeiros 4 bytes, módulo 100. Se o bucket for menor que a porcentagem, retorna `true`.

Buckets para a flag `novo-checkout`:

| user_id | bucket | 50% |
|---|---|---|
| u1 | 26 | true |
| u5 | 22 | true |
| u9 | 5 | true |
| u2 | 61 | false |
| u3 | 69 | false |
| u10 | 87 | false |

**5. Confirmar o cache**

```bash
kubectl logs -n evaluation-service -l app=evaluation-service --tail=20 | grep -i cache
```

`Cache MISS` na primeira chamada, `Cache HIT` nas seguintes, e novo `MISS` após o TTL de 30 segundos. É a justificativa concreta do ElastiCache no desenho.

> Ao **alterar** uma regra, espere 30 segundos antes de testar: o cache ainda serve o valor antigo.

**6. Confirmar a persistência dos eventos**

```bash
kubectl get pods -n analytics-service -l app=analytics-service
aws dynamodb scan --region $REGION --table-name $TABLE --select COUNT
```

---

## 6. Demonstração de escalabilidade

### 6.1 KEDA: analytics-service escalando por profundidade de fila

Mostre primeiro o estado inativo, que é o contraste mais visual:

```bash
kubectl get pods -n analytics-service -l app=analytics-service   # nenhum pod
kubectl get scaledobject -n analytics-service                     # ACTIVE: False
```

Acompanhe em dois terminais:

```bash
# terminal 1
watch -n2 'kubectl get pods -n analytics-service -l app=analytics-service; echo; \
           kubectl get hpa -n analytics-service'
```

```bash
# terminal 2 — 500 mensagens em lotes de 10 (carregue antes as variáveis da seção 5.0)
for b in $(seq 1 50); do
  ENTRIES=$(python3 -c "
import json,sys
b=sys.argv[1]
print(json.dumps([{'Id':f'm{b}-{i}',
  'MessageBody':json.dumps({'user_id':f'u{b}-{i}','flag_name':'novo-checkout',
                            'result':True,'timestamp':'2026-07-30T23:59:00Z'})}
  for i in range(10)]))" $b)
  aws sqs send-message-batch --region "$REGION" --queue-url "$QUEUE" --entries "$ENTRIES" >/dev/null
done
```

Com `queueLength: 5`, 500 mensagens pedem os 10 pods do teto. O `TARGETS` mostra a profundidade da fila por pod: a prova de que a métrica de escala é a fila, não CPU.

Para manter os pods de pé durante a narração, rode o laço acima dentro de um `while true; do ... sleep 5; done` e interrompa com `Ctrl+C` quando quiser mostrar o retorno a zero.

```bash
aws dynamodb scan --region $REGION --table-name $TABLE --select COUNT
```

**Por que KEDA e não HPA por CPU neste serviço:** a fila pode acumular centenas de mensagens com a CPU baixa, porque o worker fica bloqueado em I/O esperando o `receive_message`. O HPA por CPU não veria pressão nenhuma. Além disso, só o KEDA escala a partir de zero.

### 6.2 HPA: evaluation-service escalando por CPU

```bash
# terminal 1
watch -n2 'kubectl get hpa evaluation-service -n evaluation-service; echo; \
           kubectl get pods -n evaluation-service -l app=evaluation-service'
```

```bash
# terminal 2 — 50 requisições em paralelo, sem instalar nada
seq 1 200000 | xargs -P 50 -I{} \
  curl -s -o /dev/null "$NLB/evaluate?user_id=u1&flag_name=novo-checkout"
```

O `TARGETS` sai de ~1% e passa de 70%; as réplicas vão de 2 a 6.

Se a CPU não subir, sua conexão é o gargalo: o serviço é Go e responde do cache, consumindo pouquíssimo por requisição. Gere a carga de dentro do cluster, no namespace `default`, chamando o Service pelo DNS interno:

```bash
for i in 1 2 3; do
  kubectl run load-$i --image=$ECR/mirror/library/redis:7-alpine --restart=Never -- sh -c \
    'while true; do wget -q -O /dev/null "http://evaluation-service.evaluation-service.svc:8004/evaluate?user_id=u1&flag_name=novo-checkout"; done'
done

# limpar depois
kubectl delete pod load-1 load-2 load-3
```

(A imagem do Redis é usada só pelo `wget` do Alpine que vem nela: evita espelhar mais uma imagem.)

---

## 7. Destruir um ambiente

Na ordem inversa da criação, conferindo entre os passos. O roteiro completo, com a verificação final por região, está em [`terraform/README.md`](terraform/README.md#destruir-um-ambiente).

```bash
cd $INFRA/terraform
./tf.sh cluster-addons develop destroy     # 1. remove NLB e volume do OpenBao
aws elbv2 describe-load-balancers --region us-east-2 --query 'LoadBalancers[].LoadBalancerName'   # 2. precisa ser []
./tf.sh infra develop destroy              # 3. recursos AWS do ambiente
aws secretsmanager delete-secret --region us-east-2 \
  --secret-id togglemaster/develop/openbao-init --force-delete-without-recovery   # 4. segredo do bootstrap
```

Pela pipeline: **Actions → terraform → Run workflow**, ambiente e ação `destroy`. O job faz os quatro passos, incluindo a espera pelos load balancers e o segredo do OpenBao.

**Por que o `cluster-addons` antes do `infra`.** O NLB foi criado pelo aws-load-balancer-controller dentro do cluster e não está no state do Terraform. Destruindo o cluster antes, o NLB fica órfão: continua cobrando e o `destroy` da VPC falha com `DependencyViolation`, porque ainda há um recurso pendurado nas sub-redes. Pelo mesmo motivo o PVC do OpenBao usa `whenDeleted: Delete`: o volume EBS sai junto com o chart.

**O que sobra de propósito**

| Recurso | Motivo | Cobra? |
|---|---|---|
| bucket do state, ECR, OIDC, roles da CI, orçamento | stacks `bootstrap` e `global`, compartilhados pelos ambientes | centavos de storage |
| repositórios `k8s/*`, `ecr-public/*`, `mirror/*` | cache e espelho de imagens de terceiros | centavos de storage |
| chaves KMS do ambiente em `PendingDeletion` | janela de 7 dias, proteção contra perda de dados | não |
| log groups `/aws/eks/...` e `/aws/rds/...` | nem sempre removidos | centavos |

Os repositórios de cache e espelho **vale a pena manter** entre sessões: economizam os ~5 minutos do `mirror-images.sh` e o primeiro pull de cada imagem.

---

## 8. Custos

Estimativa de **um ambiente ligado**, com as escolhas deste projeto (os preços de us-east-2 e us-west-2 são praticamente os mesmos de us-east-1):

| Recurso | Custo/hora | Custo/dia |
|---|---|---|
| EKS control plane | US$0,10 | US$2,40 |
| 2x `c7i-flex.large` On-Demand | ~US$0,17 | ~US$4,08 |
| 1x NAT Gateway | ~US$0,045 | ~US$1,10 |
| 3x RDS `db.t3.micro` | ~US$0,051 | ~US$1,22 |
| ElastiCache `cache.t3.micro` | ~US$0,017 | ~US$0,41 |
| NLB | ~US$0,023 | ~US$0,60 |
| DynamoDB / SQS / KMS | mínimo | ~US$0,10 |
| **Total por ambiente** | **~US$0,41** | **~US$9,90** |

Os três ambientes ligados ao mesmo tempo custam ~US$1,25/hora. Fora isso, a conta mantém o bucket do state, o ECR e o segredo do OpenBao de cada ambiente ligado (US$0,40/mês cada), tudo na casa dos centavos.

**O padrão de uso muda tudo:**

| Uso | Custo total |
|---|---|
| 8 sessões de 4h de um ambiente (~32h) | **~US$13** |
| develop + staging + production por 3h, para a demonstração | ~US$4 |
| 1 ambiente ligado 24h por 10 dias | ~US$99 |

O maior custo é **tempo ligado**, não tamanho de instância: o control plane do EKS cobra por hora independentemente do uso e não pode ser "pausado", só destruído. Atenção também à pipeline: um push numa `release/*` ou uma tag **cria o ambiente** se ele estiver desligado.

O orçamento é criado pelo stack `global`, para a conta inteira, com alertas em 50%, 80% e previsão de 100%. O e-mail precisa ser verificado uma vez (ver [`terraform/README.md`](terraform/README.md#depois-do-global-confirmar-o-e-mail-do-orçamento)).

### Escolhas de custo embutidas (e como reverter)

| Escolha | Onde mudar (`infra/envs/<ambiente>.tfvars`) | Custo de reverter |
|---|---|---|
| 1 NAT Gateway compartilhado | `single_nat_gateway = false` | +~US$32/mês por AZ |
| RDS single-AZ | `db_multi_az = true` | 2x por instância (são 3) |
| Nós On-Demand | `node_capacity_type = "SPOT"` | economiza ~60%, com risco de interrupção |
| Sem proteção contra exclusão | `deletion_protection = true` (comentado em `production.tfvars`) | o destroy passa a exigir desligar a proteção antes |

---

## 9. Segurança

**Na esteira**

- **SAST, SCA e scan de imagem bloqueando o merge**: SonarQube Cloud (Quality Gate), Snyk ou Trivy nas dependências e Trivy na imagem antes do push no ECR. Vulnerabilidade **crítica** reprova. Detalhes em [`docs/ci-cd.md`](docs/ci-cd.md).
- **Sem chave de acesso no GitHub**: a CI assume roles da AWS por OIDC, cada uma restrita às refs que podem usá-la (`release/*`, tags `v*`, Environments).
- **Imagem imutável**: o ECR recusa sobrescrever uma tag, e a imagem promovida para staging e production é a mesma que passou por develop.
- **Produção com aprovação** (GitHub Environment) e janela de deploy no ArgoCD.

**Na AWS e no cluster**

- **Rede**: nós, RDS e ElastiCache apenas em sub-redes privadas, sem IP público. Só o NLB fica em sub-rede pública.
- **Security Groups por camada**: RDS e Redis aceitam tráfego apenas do SG dos nós do EKS, nunca de `0.0.0.0/0` nem do CIDR da VPC inteira.
- **IAM mínimo no nó**: a role dos nós tem apenas `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, ECR **read-only** e a permissão de pull-through **escopada aos prefixos de cache**.
- **IRSA por workload**: evaluation-service (`sqs:SendMessage`), analytics-service (`sqs:Receive/Delete` + `dynamodb:PutItem`), ALB controller, KEDA e OpenBao, cada um com sua própria role. **Nenhuma** `AWS_ACCESS_KEY_ID` em manifesto.
- **Segredos no OpenBao**: `DATABASE_URL`, `MASTER_KEY` e `SERVICE_API_KEY` ficam no cofre, com auto-unseal pela KMS do ambiente. O repositório GitOps só declara `ExternalSecret` (a referência), e a validação do GitOps reprova qualquer `kind: Secret`.
- **Senhas gerenciadas pelo RDS**: `manage_master_user_password = true`. A senha é gerada pelo RDS e guardada no Secrets Manager; nunca passa por código, tfvars ou state.
- **Criptografia em repouso**: RDS, ElastiCache, ECR, state do Terraform e os Secrets do etcd, todos com CMK própria.
- **TLS em trânsito** com o RDS (`sslmode=require`).
- **IMDSv2 obrigatório** nos nós, com hop limit 1: dificulta exfiltração de credenciais via SSRF.
- **Pod Security `restricted`** em cada namespace de aplicação: o cluster recusa pod que rode como root, escale privilégio ou mantenha capabilities. Os Deployments usam `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` e `capabilities: drop ALL`, e os Dockerfiles declaram `USER` (distroless `nonroot` nos serviços Go, UID 1000 nos Python).
- **DLQ na fila SQS**: após 5 tentativas a mensagem vai para a dead-letter queue em vez de travar o worker em laço infinito.

---

## 10. Estrutura do repositório

```
toggle-master-infra/
├── .github/
│   ├── workflows/
│   │   ├── terraform.yml          plan/apply/destroy da infra por ambiente
│   │   ├── service-ci.yml         CI reutilizável dos 5 serviços
│   │   ├── service-promote.yml    promoção por tag (staging, production)
│   │   ├── git-release.yml        botões de release (reutilizável)
│   │   └── release.yml            botões de release deste repositório
│   └── actions/gitops-set-image/  commit do newTag no repositório GitOps
├── docker-compose.yml             ambiente local
├── local-bootstrap.sh             prepara o ambiente local do zero
├── docs/
│   ├── ci-cd.md                   pipelines, ferramentas de segurança e setup
│   ├── fase3-cicd-gitops.drawio   diagrama da Fase 3
│   ├── arquitetura.drawio         arquitetura AWS (Fase 2)
│   └── fluxo-geral.md             fluxo funcional entre os serviços
├── scripts/
│   ├── mirror-images.sh           espelha imagens de terceiros no ECR
│   ├── openbao-bootstrap.sh       inicializa o OpenBao e grava os segredos
│   └── argocd-repo-credentials.sh só se o repositório GitOps for privado
├── terraform/                     bootstrap, global, módulos, infra e cluster-addons (ver o README da pasta)
├── Postman/                       coleção de requisições da API
└── k8s/                           LEGADO da Fase 2: substituído pelo toggle-master-gitops
```

### 10.1 Por que dois stacks por ambiente

Os providers `kubernetes` e `helm` precisam se conectar a um cluster que já exista **no momento do `plan`**. Num apply único, na primeira execução o cluster ainda não existe e o plan falha. Por isso `infra` (AWS) e `cluster-addons` (dentro do cluster) têm states separados. O `bootstrap` e o `global` ficam à parte porque pertencem à conta, não a um ambiente.

### 10.2 Origem das imagens

| Origem original | Passa a vir de | Mecanismo |
|---|---|---|
| repositórios dos serviços | `<ecr>/togglemaster/*` | CI (`service-ci.yml`), tag `vX.Y.Z-<sha>` |
| `registry.k8s.io` | `<ecr>/k8s/*` | pull-through cache (Terraform) |
| `public.ecr.aws` | `<ecr>/ecr-public/*` | pull-through cache (Terraform) |
| `ghcr.io` (KEDA) | `<ecr>/mirror/kedacore/*` | `scripts/mirror-images.sh` |
| Docker Hub (bases e testes) | `<ecr>/mirror/library/*` | `scripts/mirror-images.sh` |

O pull-through cache é declarativo e funciona sem credencial para `registry.k8s.io` e `public.ecr.aws`. Docker Hub e ghcr.io exigiriam token no Secrets Manager, por isso são espelhados por script.

Os Dockerfiles usam `ARG BASE_REGISTRY` com default no Docker Hub, para o build local continuar funcionando sem AWS.

### 10.3 Convenção de branches

```
tipo/escopo-descricao
```

| Prefixo | Quando usar |
|---|---|
| `feature/` | nova funcionalidade |
| `fix/` | correção de bug |
| `chore/` | manutenção geral |
| `docs/` | documentação |
| `release/vX.Y.Z` | criada pelo botão `criar-release`; recebe os PRs e sobe em develop |

As tags `vX.Y.Z-rc.N` (staging) e `vX.Y.Z` (production) são criadas pelos botões de promoção. Fluxo completo em [`docs/ci-cd.md`](docs/ci-cd.md).

---

## 11. Troubleshooting

Os problemas do Terraform e do provisionamento (versão, ECR de fase anterior, OIDC, OpenBao, ArgoCD, destroy) estão em [`terraform/README.md`](terraform/README.md#problemas-conhecidos).

### Ambiente local

| Sintoma | Causa |
|---|---|
| `no such file or directory` no `docker compose up` | repositórios não estão na mesma pasta pai (ver 2.1) |
| conflito de porta | outro processo usando as portas da tabela 3.3 |
| `required variable ... is missing a value` | falta criar o `.env`: rode `./local-bootstrap.sh` |
| `401` ao avaliar uma flag localmente | `SERVICE_API_KEY` inválida: rode `./local-bootstrap.sh` |
| `Acesso não autorizado` no `local-bootstrap.sh` | a `MASTER_KEY` do `.env` difere da do container: `docker compose up -d --force-recreate auth-service` |
| `Não foi possível conectar ao banco de dados` | corrida de inicialização, resolvida pelos healthchecks; se voltar a ocorrer, veja `docker compose ps` e confirme que os Postgres estão `(healthy)` |

### Terraform

| Sintoma | Causa |
|---|---|
| `AccessDenied` em `aws_budgets_budget` | falta liberar o acesso do IAM ao billing (ver 2.5) |
| `not eligible for Free Tier` no node group | tipo de instância fora da lista do free plan (ver 2.6) |
| `kubectl` com `i/o timeout` | endpoint restrito e seu IP mudou (ver [2.7](#27-restringir-o-endpoint-do-cluster-ao-seu-ip-opcional)) |
| blocos `set` marcados em vermelho no VS Code | falta rodar `terraform init` na pasta: o language server valida contra o schema mais recente |
| `context deadline exceeded` em `helm_release` | pods não ficaram prontos; investigue com `kubectl get pods -n <ns>` |
| erro de TLS no webhook do ALB controller após upgrade | certificado dessincronizado: `kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system` |

### Cluster e aplicação

| Sintoma | Causa |
|---|---|
| Application `Degraded` com `ImagePullBackOff` | a tag do overlay não existe no ECR (normal até a primeira CI, overlay em `v0.0.0`), ou faltou o `mirror-images.sh` |
| Application `OutOfSync` com sync falhando | veja o Job de migração do banco (`kubectl get jobs -n <serviço>`): ele roda antes do Deployment e, se falhar, o sync para |
| `pods "x" is forbidden: violates PodSecurity "restricted"` | pod de teste num namespace de aplicação: use a função `psa_run` da seção 5.0 |
| `CreateContainerConfigError` | Secret ausente: confira o ExternalSecret do serviço (`kubectl get externalsecrets -n <serviço>`) |
| `exec format error` | imagem arm64 em nó amd64: rebuilde com `--platform linux/amd64` |
| pod Python em `CrashLoopBackOff` | veja `kubectl logs`; frequentemente é a `DATABASE_URL` |
| `AccessDenied` da AWS nos logs do pod | ServiceAccount sem a anotação de IRSA do ambiente (overlay) |
| Ingress com `EXTERNAL-IP <pending>` | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| HPA com `TARGETS <unknown>` | metrics-server ainda coletando (aguarde ~60s) ou não instalado |
| ScaledObject sem escalar | `kubectl logs -n keda deploy/keda-operator`: quase sempre IRSA |
| mudança feita com `kubectl` some sozinha | é o `selfHeal` do ArgoCD: mude pelo repositório GitOps |

### Debugar valores de Helm chart

O Helm aceita qualquer `--set` **sem validar**: uma chave inexistente não gera erro nem aviso, simplesmente não faz nada. Antes de aplicar, renderize localmente:

```bash
helm template <release> <repo>/<chart> --version <ver> --set <chave>=<valor> | grep "image:"
```

Cada chart estrutura o endereço da imagem de um jeito diferente: alguns usam `image.repository` com o endereço completo, outros separam `image.registry` do caminho, e o KEDA define o registry **por componente**.
