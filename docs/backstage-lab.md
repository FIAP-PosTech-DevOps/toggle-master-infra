# Laboratório Backstage

Portal do desenvolvedor com **todos os repositórios, pipelines, deploys e pods** do ToggleMaster num lugar só. Ele é separado dos ambientes da aplicação: sobe só quando for usado e é destruído no fim da sessão.

| O que o Backstage mostra | De onde vem |
|---|---|
| Catálogo: 5 serviços, infra, GitOps, o próprio Backstage, recursos AWS e dependências | `catalog-info.yaml` de cada repositório + `catalog/all.yaml` do toggle-master-backstage |
| Aba **CI/CD**: runs do GitHub Actions | API do GitHub, com o login de quem está navegando |
| Aba **Kubernetes**: pods, deployments, HPA por ambiente | Clusters EKS no ar (leitura via Access Entry) |
| Aba **Argo CD**: status de sync e histórico por ambiente | ArgoCD de cada cluster no ar |
| Aba **Docs**: README de cada repositório | TechDocs (`mkdocs.yml` + `docs/`) |

## Arquitetura

```
sua máquina ──SSM port-forward──► EC2 c7i-flex.large (VPC própria, sem porta de entrada)
localhost:7007                     ├─ backstage   (imagem togglemaster/backstage do ECR)
                                   ├─ postgres    (catálogo, só 127.0.0.1)
                                   └─ kubectl port-forward ──► argocd-server de cada cluster no ar
```

- **Separado dos ambientes:** stack `terraform/tooling` com state próprio e workflow próprio (`tooling.yml`). Subir ou destruir o laboratório nunca toca develop, staging ou production.
- **Um Backstage para os 3 ambientes:** a cada 2 minutos a EC2 procura os clusters `togglemaster-<ambiente>-cluster` no ar e atualiza a configuração. Um ambiente que sobe depois aparece sozinho; um que é destruído some.
- **Sem porta aberta:** o Security Group não tem regra de entrada. O acesso é pelo Session Manager, com as suas credenciais AWS.
- **Acesso aos clusters só de leitura:** a role da EC2 (`togglemaster-backstage`, stack global) recebe `AmazonEKSViewPolicy` em cada cluster. O cluster-addons libera, só no namespace `argocd`, o port-forward até a API do ArgoCD e a leitura da senha inicial dele.

| Peça | Stack | Existe quando |
|---|---|---|
| Repositório ECR `togglemaster/backstage`, role e instance profile `togglemaster-backstage` | `global` | Sempre (custo ~zero) |
| Access Entry de leitura nos clusters | `infra` (módulo eks) | Junto de cada cluster, se a role existir |
| Role/RoleBinding do port-forward no namespace `argocd` | `cluster-addons` | Junto de cada cluster |
| VPC mínima + EC2 + Security Group | `tooling` | Só durante o laboratório |

**Custo:** cerca de **US$ 0,09/hora** com o laboratório no ar (EC2 `c7i-flex.large` + IP público + disco). Destruído, sobra só o repositório ECR (centavos por mês).

## Preparação (uma vez)

### 1. Repositório do Backstage

1. Crie o repositório **público** `toggle-master-backstage` na organização, vazio.
2. Anote o ID numérico dele:
   ```bash
   curl -s https://api.github.com/repos/FIAP-PosTech-DevOps/toggle-master-backstage | jq .id
   ```
3. Em *Settings › Environments*, crie o Environment **`tooling`** (sem revisores).
4. Em *Settings › Secrets and variables › Actions › Variables*, crie `AWS_ACCOUNT_ID`.

### 2. Stack global

No `terraform/global/terraform.tfvars` (não versionado), acrescente o ID do passo anterior:

```hcl
backstage_repository_id = 1234567890
```

E aplique:

```bash
cd terraform
./tf.sh global plan
./tf.sh global apply
```

Cria o ECR `togglemaster/backstage`, a role e o instance profile `togglemaster-backstage`, libera o push da esteira do Backstage e acrescenta o Environment `tooling` na role de apply.

### 3. Environment `tooling` neste repositório

*Settings › Environments › New environment* → `tooling`, sem revisores. É o que libera a role de apply para o workflow `tooling.yml`.

### 4. Login com GitHub (OAuth App)

*Organização › Settings › Developer settings › OAuth Apps › New OAuth App*:

| Campo | Valor |
|---|---|
| Homepage URL | `http://localhost:7007` |
| Authorization callback URL | `http://localhost:7007/api/auth/github/handler/frame` |

Gere um **client secret**.

### 5. Token de leitura do GitHub

*Settings (sua conta) › Developer settings › Fine-grained tokens*: dono **FIAP-PosTech-DevOps**, acesso **Public repositories (read-only)**. O Backstage usa para ler os `catalog-info.yaml` e as docs.

### 6. Segredos no SSM Parameter Store

Nada vai para arquivo nem para o chat. Os comandos pedem o valor sem mostrar na tela:

```bash
for p in github-client-id github-client-secret github-token; do
  read -rsp "$p: " V; echo
  aws ssm put-parameter --region us-east-1 --type SecureString --overwrite \
    --name "/togglemaster/backstage/$p" --value "$V" >/dev/null
done; unset V
```

Parâmetros *Standard* não têm custo.

### 7. Imagem

Faça o push do app para a `main` do `toggle-master-backstage`. A esteira `build` gera e publica `togglemaster/backstage:latest` no ECR (cerca de 10 minutos na primeira vez).

### 8. Session Manager plugin na sua máquina

Necessário para o túnel: [instalação do Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

## Uso (cada laboratório)

1. **Subir:** *Actions › tooling › Run workflow* → `apply`. O Terraform leva ~2 minutos; a instalação na EC2, mais ~5.
2. **Abrir o túnel** com o comando que aparece no resumo do run:
   ```bash
   aws ssm start-session --region us-east-1 --target i-xxxxxxxx \
     --document-name AWS-StartPortForwardingSession \
     --parameters portNumber=7007,localPortNumber=7007
   ```
3. Abrir **http://localhost:7007** e entrar com o GitHub.
4. **Destruir no fim:** *Actions › tooling › Run workflow* → `destroy`.

Os ambientes (develop, staging, production) podem subir antes ou depois do laboratório: em até 2 minutos eles aparecem nas abas Kubernetes e Argo CD.

## Diagnóstico

Entre na EC2 pelo Session Manager (`aws ssm start-session --region us-east-1 --target i-xxxxxxxx`) e use:

| Comando | Para quê |
|---|---|
| `sudo tail -f /var/log/backstage-bootstrap.log` | Instalação (Docker, imagem, primeira configuração) |
| `sudo docker logs -f backstage` | Log do Backstage |
| `sudo /opt/backstage/lab-refresh.sh` | Forçar a releitura dos clusters agora |
| `systemctl status 'argocd-pf@*'` | Port-forwards até os ArgoCD |

O arquivo `/opt/backstage/app-config.lab.yaml` contém a senha do ArgoCD de cada ambiente: não mostre na gravação.

## Limitações conhecidas

- **Laboratório, não produção:** uma EC2 numa AZ, sem backup do Postgres (o catálogo é refeito a partir dos repositórios em minutos).
- **Senha do ArgoCD:** o plugin usa o usuário `admin` (senha inicial). Numa instalação definitiva, o certo é uma conta local do ArgoCD só de leitura, com token próprio.
- **Acesso só para quem tem credencial AWS na conta:** o túnel usa o Session Manager. Para colegas sem acesso à conta, seria preciso expor o Backstage com HTTPS (ALB + domínio), o que custa mais.
