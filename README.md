# ToggleMaster — Infraestrutura

Infraestrutura do ToggleMaster, uma plataforma de feature flags composta por 5 microsserviços. Este repositório cobre os dois ambientes:

- **Local** — Docker Compose com LocalStack, para desenvolvimento
- **AWS** — Kubernetes gerenciado (EKS) provisionado por Terraform, para simular produção

## Índice

1. [Arquitetura](#1-arquitetura)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Ambiente local (Docker Compose)](#3-ambiente-local-docker-compose)
4. [Construir o laboratório na AWS](#4-construir-o-laboratório-na-aws)
5. [Testes e validação](#5-testes-e-validação)
6. [Demonstração de escalabilidade](#6-demonstração-de-escalabilidade)
7. [Destruir o laboratório](#7-destruir-o-laboratório)
8. [Custos](#8-custos)
9. [Segurança](#9-segurança)
10. [Estrutura do repositório](#10-estrutura-do-repositório)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Arquitetura

> Diagrama completo em [`docs/arquitetura.drawio`](docs/arquitetura.drawio), com três páginas: arquitetura AWS, segurança/IRSA e fluxo de provisionamento. Abra em [app.diagrams.net](https://app.diagrams.net) ou pela extensão Draw.io Integration do VS Code.

| Serviço | Linguagem | Porta | Persistência | Repositório |
|---|---|---|---|---|
| auth-service | Go | 8001 | PostgreSQL | [auth-service](https://github.com/FIAP-POS-TECH-CHALLENGE/auth-service) |
| flag-service | Python | 8002 | PostgreSQL | [flag-service](https://github.com/FIAP-POS-TECH-CHALLENGE/flag-service) |
| targeting-service | Python | 8003 | PostgreSQL | [targeting-service](https://github.com/FIAP-POS-TECH-CHALLENGE/targeting-service) |
| evaluation-service | Go | 8004 | Redis (cache) | [evaluation-service](https://github.com/FIAP-POS-TECH-CHALLENGE/evaluation-service) |
| analytics-service | Python | 8005 | DynamoDB | [analytics-service](https://github.com/FIAP-POS-TECH-CHALLENGE/analytics-service) |

### Fluxo de uma avaliação

```
cliente → Ingress (NLB) → evaluation-service
                              ├─ Redis (cache, TTL 30s)
                              ├─ flag-service      → PostgreSQL
                              ├─ targeting-service → PostgreSQL
                              └─ SQS → analytics-service → DynamoDB
```

O `evaluation-service` é o caminho quente: responde do Redis sempre que possível e publica o evento na fila de forma assíncrona, sem bloquear a resposta.

### Por que três data stores diferentes

| Store | Uso | Motivo |
|---|---|---|
| **RDS PostgreSQL** | definições de flags, regras, chaves de API | dados relacionais, consultados por chave de negócio, com integridade transacional |
| **ElastiCache Redis** | cache do caminho quente | leitura sub-milissegundo; evita bater no banco a cada avaliação |
| **DynamoDB** | eventos de analytics | volume alto de escrita, schema simples por chave, sem relacionamento |

### Equivalência entre os ambientes

| Local (Docker Compose) | AWS |
|---|---|
| 3 containers PostgreSQL | 3 instâncias RDS PostgreSQL |
| container Redis | ElastiCache Redis |
| LocalStack (SQS + DynamoDB) | SQS e DynamoDB reais |
| build local das imagens | ECR privado |
| — | EKS, Ingress/NLB, HPA, KEDA |

---

## 2. Pré-requisitos

### 2.1 Estrutura de pastas

Tanto o `docker-compose.yml` quanto os scripts de build referenciam os serviços por caminho relativo. **Todos os repositórios precisam estar clonados na mesma pasta pai:**

```
ToggleMaster/
├── toggle-master-infra/     ← este repositório
├── auth-service/
├── flag-service/
├── targeting-service/
├── evaluation-service/
└── analytics-service/
```

```bash
mkdir ToggleMaster && cd ToggleMaster
for r in toggle-master-infra auth-service flag-service targeting-service evaluation-service analytics-service; do
  git clone https://github.com/FIAP-POS-TECH-CHALLENGE/$r.git $r
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
| Terraform | AWS | 1.6 |
| AWS CLI | AWS | v2 |
| kubectl | AWS | — |
| helm | AWS | 3.x |
| jq, python3, envsubst | scripts | — |

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
```

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

**5. Helm**

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**6. Utilitários usados pelos scripts**

```bash
sudo apt install -y jq python3 gettext-base
```

**macOS**

```bash
brew install --cask docker
brew install terraform awscli kubernetes-cli helm jq gettext
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
jq --version && python3 --version && envsubst --version | head -1
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

```bash
cd $INFRA/terraform/infra
cp terraform.tfvars.example terraform.tfvars
```

Três linhas obrigatórias:

```hcl
alert_email                          = "seu-email@exemplo.com"
cluster_version                      = "1.36"
cluster_endpoint_public_access_cidrs = ["SEU.IP.PUBLICO/32"]
```

- **`alert_email`** — recebe os alertas de orçamento (50%, 80% e previsão de 100%)
- **`cluster_version`** — confira as versões em standard support com `aws eks describe-cluster-versions --output table`. Uma versão em *extended support* custa **US$0,60/hora** em vez de US$0,10 — seis vezes mais
- **`cluster_endpoint_public_access_cidrs`** — seu IP público, com `/32` no final. Descubra com:

```bash
curl -s checkip.amazonaws.com
```

> Contas criadas a partir de 15/07/2025 entram no *free plan* e só conseguem lançar `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large` e `m7i-flex.large`. O default do projeto é `c7i-flex.large`. Confirme a sua lista com `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType' --output text`.

### 2.7 Quando o seu IP mudar

IP residencial é dinâmico: o provedor troca sozinho, e trocar de rede (celular, VPN, outro wi-fi) também muda. Quando isso acontece, o `kubectl` para de responder com **`i/o timeout`** — seus pacotes passam a ser descartados pela allowlist do endpoint.

O tipo do erro identifica a causa sem investigação:

| Erro do kubectl | Causa |
|---|---|
| `i/o timeout` | **seu IP não está na allowlist** |
| `no such host` | o cluster não existe (foi destruído) |
| `connection refused` em `localhost:8080` | kubeconfig sem contexto ativo |

**Verificar:**

```bash
cd $INFRA/terraform/infra

echo "IP atual:    $(curl -s checkip.amazonaws.com)"
echo "IP liberado: $(grep cluster_endpoint terraform.tfvars)"
```

**Atualizar**, se forem diferentes:

```bash
IP_NOVO=$(curl -s checkip.amazonaws.com)
sed -i -E "s|cluster_endpoint_public_access_cidrs = \[\"[0-9./]+\"\]|cluster_endpoint_public_access_cidrs = [\"$IP_NOVO/32\"]|" terraform.tfvars

grep cluster_endpoint terraform.tfvars    # confira antes de aplicar
terraform apply                            # deve mostrar "1 to change, 0 to destroy"
```

Leva 1-2 minutos e não recria nada — só atualiza a configuração de acesso do endpoint.

```bash
kubectl get nodes
```

**Se você alterna entre redes conhecidas**, liste todas em vez de trocar toda vez:

```hcl
cluster_endpoint_public_access_cidrs = [
  "200.102.105.118/32",   # casa
  "203.0.113.42/32",      # escritório
]
```

**Se o valor no tfvars já estiver correto** e mesmo assim der timeout, confirme o que a AWS realmente aplicou — pode divergir se o último `apply` não completou:

```bash
aws eks describe-cluster --name togglemaster-lab-cluster --region us-east-1 \
  --query 'cluster.resourcesVpcConfig.[endpointPublicAccess,publicAccessCidrs]'

aws eks describe-cluster --name togglemaster-lab-cluster --region us-east-1 \
  --query 'cluster.status' --output text     # precisa estar ACTIVE
```

Esses comandos falam com a API da AWS, não com o endpoint do Kubernetes — funcionam mesmo com o `kubectl` bloqueado.

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

## 4. Construir o laboratório na AWS

Seis fases, ~45 minutos no total — a maior parte esperando a AWS.

### Fase 1 — Infraestrutura (~20 min)

```bash
cd $INFRA/terraform/infra
terraform init
terraform validate
terraform plan     # confira: ~68 to add, 0 to destroy
terraform apply
```

Cria VPC, EKS, node group, 3 RDS, ElastiCache, DynamoDB, SQS + DLQ, ECR, roles IRSA, KMS, regras de pull-through cache e o alarme de orçamento.

O control plane do EKS sozinho leva ~12 minutos. O terminal vai parecer travado em `Still creating...` — é normal, não cancele.

### Fase 2 — Conectar o kubectl

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-east-1
kubectl get nodes     # 2 nós Ready
```

**Obrigatório a cada ciclo.** O cluster é recriado do zero, então o endpoint e o certificado mudam.

### Fase 3 — Espelhar as imagens de terceiros (~5 min)

```bash
cd $INFRA/k8s
./mirror-images.sh
```

Copia para o ECR privado as imagens do KEDA (ghcr.io) e as imagens base dos Dockerfiles (Docker Hub). Precisa vir **antes** da fase 4: o KEDA aponta para o espelho, e sem ele os pods ficam em `ImagePullBackOff`.

### Fase 4 — Addons do cluster (~5 min)

```bash
cd $INFRA/terraform/cluster-addons
terraform init
terraform apply
```

Instala metrics-server, aws-load-balancer-controller, ingress-nginx e KEDA, além do namespace `togglemaster` e das Service Accounts com IRSA.

```bash
kubectl get pods -n kube-system | grep -E 'metrics-server|load-balancer'
kubectl get pods -n keda
kubectl get svc -n ingress-nginx ingress-nginx-controller   # EXTERNAL-IP em 2-3 min
```

### Fase 5 — Build e push das imagens (~6 min)

```bash
cd $INFRA/k8s
./build-and-push.sh v1
```

Os repositórios ECR são **IMMUTABLE**: subir `:v1` uma segunda vez falha de propósito. Ao iterar, use `v2`, `v3`, ou o SHA do commit:

```bash
./build-and-push.sh $(git rev-parse --short HEAD)
```

### Fase 6 — Deploy da aplicação (~4 min)

```bash
./deploy.sh v1
```

O script carrega os `init.sql` nos 3 bancos, gera ConfigMap e Secrets a partir dos outputs do Terraform, sobe o auth-service, cria a `SERVICE_API_KEY` via `POST /admin/keys` e então sobe os outros 4 serviços, o Ingress, o HPA e o KEDA.

A `MASTER_KEY` é gerada na primeira execução e preservada nas seguintes. Não precisa anotá-la: fica no Secret `auth-service-secret` e o `env.sh` a recupera de lá.

### Deploy parcial

No dia a dia você raramente redeploya tudo — corrige o que mudou e sobe só isso. Os dois scripts aceitam lista de serviços:

```bash
cd $INFRA/k8s

# um serviço
./build-and-push.sh v2 flag-service
./deploy-service.sh flag-service v2

# dois ou três
./build-and-push.sh v2 flag-service targeting-service
./deploy-service.sh flag-service targeting-service v2

# tudo
./build-and-push.sh v2
./deploy.sh v2
```

A ordem dos argumentos é livre — nomes de serviço são reconhecidos pela lista conhecida e o argumento restante vira a tag. Com vários serviços, o `deploy-service.sh` reordena por dependência (auth-service primeiro) e imprime um resumo com ✓ e ✗ ao final, mostrando onde parou caso algum falhe.

Ele não toca nos outros serviços, no Ingress nem no ConfigMap compartilhado. Antes de aplicar, confere se a imagem existe no ECR — evita subir um Deployment que ficaria em `ImagePullBackOff`.

Cada serviço pode estar numa tag diferente. Para ver o que está rodando:

```bash
kubectl get deploy -n togglemaster \
  -o custom-columns='SERVIÇO:.metadata.name,IMAGEM:.spec.template.spec.containers[0].image'
```

**Rollback**, se a versão nova tiver problema:

```bash
kubectl rollout undo deploy/flag-service -n togglemaster
kubectl rollout history deploy/flag-service -n togglemaster
```

Casos particulares:

| Situação | Comando |
|---|---|
| Recarregar o schema de um banco | `./deploy-service.sh flag-service v2 --with-schema` |
| Rotacionar a `SERVICE_API_KEY` | `./bootstrap-apikey.sh --force` |
| Ver as opções do script | `./deploy-service.sh --help` |

---

## 5. Testes e validação

### 5.0 Variáveis da sessão

Os comandos das seções 5 e 6 usam variáveis que **mudam a cada ciclo** — a AWS gera sufixos aleatórios nos endpoints e o `deploy.sh` sorteia uma `MASTER_KEY` nova a cada execução. Carregue-as com:

```bash
source $INFRA/k8s/env.sh
```

> Precisa ser `source`, não `./env.sh`. Executado normalmente, o script roda num subshell e as variáveis morrem junto com ele. O próprio script recusa a execução direta.

Ele define e confere sete variáveis:

| Variável | Origem |
|---|---|
| `CLUSTER` | output do Terraform |
| `ECR` | output do Terraform — host do registry |
| `QUEUE` | output do Terraform — URL da fila SQS |
| `TABLE` | output do Terraform — tabela DynamoDB |
| `REDIS` | output do Terraform — endpoint do ElastiCache |
| `NLB` | `kubectl` — hostname do Load Balancer |
| `MASTER_KEY` | Secret `auth-service-secret` no cluster |

Se alguma ficar vazia, o script diz o motivo provável e o comando para resolver — módulo `infra` não aplicado, Load Balancer ainda provisionando ou `deploy.sh` não executado.

**Repita o `source` a cada terminal novo.** Variável de ambiente existe só no shell onde foi definida — abrir uma aba nova zera tudo.

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

**Conectividade com o RDS** — valida security group, subnet group, DNS privado e credenciais de uma vez:

```bash
SENHA=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform output -json rds_master_user_secret_arns | jq -r .auth) \
  --query SecretString --output text | jq -r .password)
ENDPOINT=$(terraform output -json rds_endpoints | jq -r .auth | cut -d: -f1)

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

> As imagens de teste vêm do ECR, como todo o resto. O `aws-cli` usado a seguir vem de `public.ecr.aws` via pull-through cache — o repositório é criado sozinho no primeiro uso.

**IRSA concedendo o permitido**

```bash
kubectl run irsa-ok -n togglemaster --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"analytics-service-sa"}}' \
  --image=$ECR/ecr-public/aws-cli/aws-cli -- \
  sqs get-queue-attributes --queue-url $QUEUE \
    --attribute-names ApproximateNumberOfMessages
sleep 20 && kubectl logs -n togglemaster irsa-ok && kubectl delete pod -n togglemaster irsa-ok
```

**IRSA negando o não permitido** — aqui o resultado correto é `AccessDenied`:

```bash
kubectl run irsa-deny -n togglemaster --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"analytics-service-sa"}}' \
  --image=$ECR/ecr-public/aws-cli/aws-cli -- \
  dynamodb scan --table-name $TABLE
sleep 20 && kubectl logs -n togglemaster irsa-deny && kubectl delete pod -n togglemaster irsa-deny
```

A role do analytics tem apenas `dynamodb:PutItem`. Vale gravar essa tela: prova que a permissão é granular, não um `*`.

**Nenhuma imagem vinda de registro público**

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
```

Tudo deve começar com `<conta>.dkr.ecr.us-east-1.amazonaws.com/`. As únicas exceções são `aws-node` e `kube-proxy`, addons gerenciados pela própria AWS.

### 5.2 Validação funcional dos endpoints

Usa `$NLB` e `$MASTER_KEY`, definidos em [5.0](#50-variáveis-da-sessão). A `MASTER_KEY` é lida do Secret, então você não depende de ter guardado a saída do `deploy.sh`.

**Rotas expostas pelo Ingress**

| Rota | Serviço | Autenticação |
|---|---|---|
| `POST /admin/keys` | auth-service | `MASTER_KEY` |
| `GET /validate` | auth-service | API key |
| `POST/GET/PUT/DELETE /flags` | flag-service | API key |
| `POST/GET/PUT/DELETE /rules` | targeting-service | API key |
| `GET /evaluate` | evaluation-service | nenhuma |

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

Se o `jq` reclamar de `Invalid numeric literal`, a resposta não era JSON — quase sempre `Acesso não autorizado` por `MASTER_KEY` errada, ou uma página de erro do nginx porque o `$NLB` está vazio. O `echo "$RESP"` mostra qual dos dois é.

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

> O `evaluator.go` implementa **apenas** `PERCENTAGE`. O `USER_LIST` aparece como exemplo no `init.sql` mas ainda não foi implementado — qualquer outro tipo cai no `return false`.

**4. Avaliar** — query parameters, sem autenticação:

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
kubectl logs -n togglemaster -l app=evaluation-service --tail=20 | grep -i cache
```

`Cache MISS` na primeira chamada, `Cache HIT` nas seguintes, e novo `MISS` após o TTL de 30 segundos. É a justificativa concreta do ElastiCache no desenho.

> Ao **alterar** uma regra, espere 30 segundos antes de testar — o cache ainda serve o valor antigo.

**6. Confirmar a persistência dos eventos**

```bash
kubectl get pods -n togglemaster -l app=analytics-service
aws dynamodb scan --table-name $TABLE --select COUNT
```

---

## 6. Demonstração de escalabilidade

### 6.1 KEDA — analytics-service escalando por profundidade de fila

Mostre primeiro o estado inativo, que é o contraste mais visual:

```bash
kubectl get pods -n togglemaster -l app=analytics-service   # nenhum pod
kubectl get scaledobject -n togglemaster                     # ACTIVE: False
```

Acompanhe em dois terminais:

```bash
# terminal 1
watch -n2 'kubectl get pods -n togglemaster -l app=analytics-service; echo; \
           kubectl get hpa keda-hpa-analytics-service-scaledobject -n togglemaster'
```

```bash
# terminal 2 — 500 mensagens em lotes de 10
for b in $(seq 1 50); do
  ENTRIES=$(python3 -c "
import json,sys
b=sys.argv[1]
print(json.dumps([{'Id':f'm{b}-{i}',
  'MessageBody':json.dumps({'user_id':f'u{b}-{i}','flag_name':'novo-checkout',
                            'result':True,'timestamp':'2026-07-30T23:59:00Z'})}
  for i in range(10)]))" $b)
  aws sqs send-message-batch --queue-url "$QUEUE" --entries "$ENTRIES" >/dev/null
done
```

Com `queueLength: 5`, 500 mensagens pedem os 10 pods do teto. O `TARGETS` mostra a profundidade da fila por pod — a prova de que a métrica de escala é a fila, não CPU.

Para manter os pods de pé durante a narração, rode o laço acima dentro de um `while true; do ... sleep 5; done` e interrompa com `Ctrl+C` quando quiser mostrar o retorno a zero.

```bash
aws dynamodb scan --table-name $TABLE --select COUNT
```

**Por que KEDA e não HPA por CPU neste serviço:** a fila pode acumular centenas de mensagens com a CPU baixa, porque o worker fica bloqueado em I/O esperando o `receive_message`. O HPA por CPU não veria pressão nenhuma. Além disso, só o KEDA escala a partir de zero.

### 6.2 HPA — evaluation-service escalando por CPU

```bash
# terminal 1
watch -n2 'kubectl get hpa evaluation-service-hpa -n togglemaster; echo; \
           kubectl get pods -n togglemaster -l app=evaluation-service'
```

```bash
# terminal 2 — 50 requisições em paralelo, sem instalar nada
seq 1 200000 | xargs -P 50 -I{} \
  curl -s -o /dev/null "$NLB/evaluate?user_id=u1&flag_name=novo-checkout"
```

O `TARGETS` sai de ~1% e passa de 70%; as réplicas vão de 2 a 6.

Se a CPU não subir, sua conexão é o gargalo — o serviço é Go e responde do cache, consumindo pouquíssimo por requisição. Gere a carga de dentro do cluster:

```bash
for i in 1 2 3; do
  kubectl run load-$i -n togglemaster --image=$ECR/mirror/library/alpine:3.19 \
    --restart=Never -- sh -c \
    'while true; do wget -q -O /dev/null "http://evaluation-service:8004/evaluate?user_id=u1&flag_name=novo-checkout"; done'
done

# limpar depois
kubectl delete pod load-1 load-2 load-3 -n togglemaster
```

---

## 7. Destruir o laboratório

### 7.1 A ordem importa

**Três etapas, nesta sequência:**

```bash
cd $INFRA/k8s
./destroy.sh                          # 1. aplicação

cd $INFRA/terraform/cluster-addons
terraform destroy                     # 2. addons do cluster

cd $INFRA/terraform/infra
terraform destroy                     # 3. recursos AWS
```

**Por que a aplicação primeiro.** O `helm uninstall` do KEDA apaga os CRDs, e para apagar um CRD o Kubernetes precisa antes remover todos os recursos daquele tipo. Só que o `ScaledObject` e o `TriggerAuthentication` têm **finalizers** que apenas o operador do KEDA sabe liberar — e o operador já foi removido junto com o chart. Ninguém libera, e o `destroy` trava até estourar o timeout, com `context deadline exceeded`.

**Por que o `cluster-addons` antes do `infra`.** O NLB foi criado pelo aws-load-balancer-controller dentro do cluster e não está no state do Terraform. Destruindo o cluster antes, o NLB fica órfão: continua cobrando e o `destroy` da VPC falha porque ainda há um recurso pendurado nas sub-redes.

#### Se o destroy do KEDA já travou

```bash
kubectl patch scaledobject analytics-service-scaledobject -n togglemaster \
  --type=merge -p '{"metadata":{"finalizers":null}}'

kubectl delete scaledobject,triggerauthentication --all -A --timeout=30s

# se os CRDs ficarem presos em Terminating
kubectl get crd -o name | grep keda.sh | \
  xargs -r -I{} kubectl patch {} --type=merge -p '{"metadata":{"finalizers":null}}'

terraform destroy
```

### 7.2 Verificar que não sobrou nada

O provider aplica a tag `Project=togglemaster` em todo recurso, o que permite uma varredura única:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=togglemaster --region us-east-1 \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

Vazio = limpo. Varredura por serviço, para os que mais custam:

```bash
aws eks list-clusters --region us-east-1 --query clusters --output text
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region us-east-1 --query 'Addresses[].PublicIp' --output text
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName' --output text
aws rds describe-db-instances --region us-east-1 --query 'DBInstances[].DBInstanceIdentifier' --output text
aws elasticache describe-replication-groups --region us-east-1 --query 'ReplicationGroups[].ReplicationGroupId' --output text
```

**NAT Gateway** e **Elastic IP** são os dois que mais importam: são caros e cobram em silêncio. Instância `Terminated` **não** cobra nada — o registro fica visível no console por cerca de uma hora e some.

### 7.3 O que sobra de propósito

| Recurso | Motivo | Cobra? |
|---|---|---|
| Chave KMS em `PendingDeletion` | janela de 7 dias, proteção contra perda de dados | não |
| Secrets agendados para deleção | janela de recuperação | não |
| Repositórios `k8s/*`, `ecr-public/*`, `mirror/*` | criados fora do state (pull-through e espelho) | centavos de storage |
| Log groups `/aws/eks/...` | nem sempre removidos | centavos |

Os repositórios de cache e espelho **vale a pena manter** entre sessões: economizam os ~5 minutos do `mirror-images.sh` e o primeiro pull de cada imagem. Para limpar mesmo assim:

```bash
for r in $(aws ecr describe-repositories --region us-east-1 \
            --query 'repositories[?starts_with(repositoryName, `k8s/`) ||
                     starts_with(repositoryName, `ecr-public/`) ||
                     starts_with(repositoryName, `mirror/`)].repositoryName' --output text); do
  aws ecr delete-repository --repository-name "$r" --force --region us-east-1
done

aws logs delete-log-group --log-group-name /aws/eks/togglemaster-lab-cluster/cluster --region us-east-1
```

---

## 8. Custos

Estimativa em `us-east-1` com as escolhas deste projeto:

| Recurso | Custo/hora | Custo/dia |
|---|---|---|
| EKS control plane | US$0,10 | US$2,40 |
| 2x `c7i-flex.large` On-Demand | ~US$0,17 | ~US$4,08 |
| 1x NAT Gateway | ~US$0,045 | ~US$1,10 |
| 3x RDS `db.t3.micro` | ~US$0,051 | ~US$1,22 |
| ElastiCache `cache.t3.micro` | ~US$0,017 | ~US$0,41 |
| NLB | ~US$0,023 | ~US$0,60 |
| DynamoDB / SQS / ECR | mínimo | ~US$0,05 |
| **Total** | **~US$0,41** | **~US$9,90** |

**O padrão de uso muda tudo:**

| Uso | Custo total |
|---|---|
| 8 sessões de 4h (~32h) | **~US$13** |
| 15 sessões de 3h (~45h) | ~US$18 |
| Ligado 24h por 10 dias | ~US$99 |

Com disciplina de `destroy` ao fim de cada sessão, o desafio inteiro cabe em ~15% de um crédito de US$100. O maior custo é **tempo ligado**, não tamanho de instância — o control plane do EKS cobra por hora independentemente do uso e não pode ser "pausado", só destruído.

O alarme do AWS Budgets é criado automaticamente pelo módulo `infra` com alertas em 50%, 80% e previsão de 100%.

### Escolhas de custo embutidas (e como reverter)

| Escolha | Onde mudar | Custo de reverter |
|---|---|---|
| 1 NAT Gateway compartilhado | `single_nat_gateway = false` | +~US$32/mês por AZ |
| RDS single-AZ | `multi_az = true` em `rds.tf` | 2x por instância (são 3) |
| Redis sem réplica | `num_cache_clusters = 2` | 2x |
| Nós On-Demand | `node_capacity_type = "SPOT"` | economiza ~60%, com risco de interrupção |

---

## 9. Segurança

- **Rede** — nós, RDS e ElastiCache apenas em sub-redes privadas, sem IP público. Só o NLB fica em sub-rede pública.
- **Security Groups por camada** — RDS e Redis aceitam tráfego apenas do SG dos nós do EKS, nunca de `0.0.0.0/0` nem do CIDR da VPC inteira.
- **IAM mínimo no nó** — a role dos nós tem apenas `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, ECR **read-only** e a permissão de pull-through **escopada aos prefixos de cache**. Nenhuma permissão de SQS, DynamoDB ou ELB.
- **IRSA por workload** — evaluation-service (`sqs:SendMessage`), analytics-service (`sqs:Receive/Delete` + `dynamodb:PutItem`), ALB controller e KEDA (`sqs:GetQueueAttributes`), cada um com sua própria role. **Nenhuma** `AWS_ACCESS_KEY_ID` em manifesto.
- **Senhas gerenciadas pelo RDS** — `manage_master_user_password = true`: a senha é gerada pelo RDS e guardada no Secrets Manager. Nunca passa por código, tfvars ou state.
- **Nenhuma credencial versionada** — no ambiente local elas vêm de um `.env` fora do git; na AWS, a `MASTER_KEY` é gerada no deploy e a `SERVICE_API_KEY` é criada em runtime via `/admin/keys`. Em ambos os casos o repositório não contém segredo algum.
- **Criptografia em repouso** — RDS, ElastiCache, ECR e os Secrets do etcd, todos com CMK própria (envelope encryption).
- **TLS em trânsito** — conexões com o RDS usam `sslmode=require`.
- **IMDSv2 obrigatório** nos nós, com hop limit 1: dificulta exfiltração de credenciais via SSRF.
- **Contêineres sem root** — `runAsNonRoot`, `runAsUser: 1000`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` e `capabilities: drop ALL`.
- **Imagens em registro privado** — nenhuma imagem vem de registro público em runtime (ver [10.2](#102-origem-das-imagens)).
- **DLQ na fila SQS** — após 5 tentativas a mensagem vai para a dead-letter queue em vez de travar o worker em laço infinito.

---

## 10. Estrutura do repositório

```
toggle-master-infra/
├── docker-compose.yml           ambiente local
├── local-bootstrap.sh           prepara o ambiente local do zero
├── docs/
│   └── arquitetura.drawio     diagramas (arquitetura, segurança, deploy)
├── terraform/
│   ├── infra/                   VPC, EKS, RDS, ElastiCache, DynamoDB, SQS, ECR, IRSA, KMS
│   └── cluster-addons/          metrics-server, ALB controller, ingress-nginx, KEDA
└── k8s/
    ├── 01..09 *.yaml            manifestos da aplicação
    ├── mirror-images.sh         espelha imagens de terceiros para o ECR
    ├── build-and-push.sh        build e push das 5 imagens
    └── deploy.sh                deploy completo da aplicação
```

Cada pasta tem seu próprio README com as decisões técnicas e as variáveis do módulo.

### 10.1 Por que dois módulos Terraform

Os providers `kubernetes` e `helm` precisam se conectar a um cluster que já exista **no momento do `plan`**. Num apply único, na primeira execução o cluster ainda não existe e o plan falha. Dois states separados é o padrão recomendado para esse cenário.

### 10.2 Origem das imagens

| Origem original | Passa a vir de | Mecanismo |
|---|---|---|
| build local | `<ecr>/togglemaster/*` | `build-and-push.sh` |
| `registry.k8s.io` | `<ecr>/k8s/*` | pull-through cache (Terraform) |
| `public.ecr.aws` | `<ecr>/ecr-public/*` | pull-through cache (Terraform) |
| `ghcr.io` (KEDA) | `<ecr>/mirror/kedacore/*` | `mirror-images.sh` |
| Docker Hub (bases) | `<ecr>/mirror/library/*` | `mirror-images.sh` |

O pull-through cache é declarativo e funciona sem credencial para `registry.k8s.io`, `public.ecr.aws` e `quay.io`. Docker Hub e ghcr.io exigiriam token no Secrets Manager, por isso são espelhados por script.

Os Dockerfiles usam `ARG BASE_REGISTRY` com default no Docker Hub, para o build local continuar funcionando sem AWS.

### 10.3 Convenção de branches

```
tipo/escopo-descricao-nome
```

| Prefixo | Quando usar |
|---|---|
| `feature/` | nova funcionalidade |
| `fix/` | correção de bug |
| `infra/` | infraestrutura, pipelines, configs |
| `chore/` | manutenção geral |
| `docs/` | documentação |

---

## 11. Troubleshooting

### Ambiente local

| Sintoma | Causa |
|---|---|
| `no such file or directory` no `docker compose up` | repositórios não estão na mesma pasta pai (ver 2.1) |
| conflito de porta | outro processo usando as portas da tabela 3.3 |
| `required variable ... is missing a value` | falta criar o `.env` — rode `./local-bootstrap.sh` |
| `401` ao avaliar uma flag localmente | `SERVICE_API_KEY` inválida — rode `./local-bootstrap.sh` |
| `Acesso não autorizado` no `local-bootstrap.sh` | a `MASTER_KEY` do `.env` difere da do container: `docker compose up -d --force-recreate auth-service` |
| `Não foi possível conectar ao banco de dados` | corrida de inicialização — resolvida pelos healthchecks; se voltar a ocorrer, veja `docker compose ps` e confirme que os Postgres estão `(healthy)` |

### Terraform

| Sintoma | Causa |
|---|---|
| `ResourceNotFoundException` no `cluster-addons` | o módulo `infra` não foi aplicado |
| `AccessDenied` em `aws_budgets_budget` | falta liberar o acesso do IAM ao billing (ver 2.5) |
| `not eligible for Free Tier` no node group | tipo de instância fora da lista do free plan (ver 2.6) |
| erro de CIDR inválido | octeto acima de 255 em `cluster_endpoint_public_access_cidrs` |
| `kubectl` com `i/o timeout` | seu IP público mudou e saiu da allowlist — ver [2.7](#27-quando-o-seu-ip-mudar) |
| blocos `set` marcados em vermelho no VS Code | falta rodar `terraform init` na pasta — o language server valida contra o schema mais recente |
| `context deadline exceeded` em `helm_release` | pods não ficaram prontos; investigue com `kubectl get pods -n <ns>` |
| erro de TLS no webhook do ALB controller após upgrade | certificado dessincronizado: `kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system` |
| `RepositoryNotEmptyException` no destroy | repositórios ECR criados **antes** de `force_delete = true` existir no config. Atributos como esse valem a partir do state, não do config — veja abaixo |

#### `RepositoryNotEmptyException` no destroy

Acontece se os repositórios foram criados antes de o `force_delete = true` estar no `ecr.tf`. Rodar `apply` para atualizar o state não é opção quando o resto da infra já foi destruído — ele tentaria recriar tudo. Esvazie pela CLI:

```bash
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  aws ecr delete-repository --repository-name togglemaster/$svc --force --region us-east-1 >/dev/null
done
terraform destroy
```

Nos ciclos seguintes não acontece: os repositórios passam a nascer já com `force_delete = true` no state.

### Cluster e aplicação

| Sintoma | Causa |
|---|---|
| `ImagePullBackOff` | faltou `mirror-images.sh`, ou a tag não existe no ECR |
| `exec format error` | imagem arm64 em nó amd64 — rebuilde com `--platform linux/amd64` |
| `CreateContainerConfigError` | Secret ou ConfigMap ausente |
| pod Python em `CrashLoopBackOff` | veja `kubectl logs`; frequentemente é a `DATABASE_URL` |
| `invalid port ... after host` no log | senha do RDS sem percent-encoding |
| `AccessDenied` da AWS nos logs do pod | Deployment sem `serviceAccountName`, ou `cluster-addons` não aplicado |
| Ingress com `EXTERNAL-IP <pending>` | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| HPA com `TARGETS <unknown>` | metrics-server ainda coletando (aguarde ~60s) ou não instalado |
| ScaledObject sem escalar | `kubectl logs -n keda deploy/keda-operator` — quase sempre IRSA |
| `kubectl` com timeout após novo apply | seu IP mudou, ou falta `aws eks update-kubeconfig` |

### Debugar valores de Helm chart

O Helm aceita qualquer `--set` **sem validar**: uma chave inexistente não gera erro nem aviso, simplesmente não faz nada. Antes de aplicar, renderize localmente:

```bash
helm template <release> <repo>/<chart> --version <ver> --set <chave>=<valor> | grep "image:"
```

Cada chart estrutura o endereço da imagem de um jeito diferente — alguns usam `image.repository` com o endereço completo, outros separam `image.registry` do caminho, e o KEDA define o registry **por componente**.
