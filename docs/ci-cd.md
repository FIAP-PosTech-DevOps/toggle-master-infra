# CI/CD e DevSecOps dos microsserviços

As pipelines dos 5 serviços são **workflows reutilizáveis** que ficam neste repositório. Cada serviço tem três arquivos curtos em `.github/workflows/` que só chamam estes:

| Neste repositório | Chamado por (em cada serviço) | Papel |
|---|---|---|
| `.github/workflows/service-ci.yml` | `ci.yml` | build, testes, lint, SAST, SCA, imagem, ECR e deploy em develop |
| `.github/workflows/service-promote.yml` | `promote.yml` | promoção por tag para staging e production |
| `.github/workflows/git-release.yml` | `release.yml` (e o `release.yml` daqui) | botões: criar release e criar as tags de promoção |
| `.github/actions/gitops-set-image` | os dois primeiros | commit do `newTag` no repositório GitOps |

Uma melhoria na pipeline, como trocar a versão do Trivy, é feita aqui uma vez e vale para os 5 serviços.

## Fluxo completo

```
feature/x ──PR──▶ release/v1.2.0 ──push──▶ ci.yml
                                            ├─ build + testes (go test | pytest)
                                            ├─ lint (golangci-lint | flake8)
                                            ├─ SAST: SonarQube Cloud ── Quality Gate reprovado = FALHA
                                            ├─ SCA: Snyk (ou Trivy fs) ─ vulnerabilidade CRÍTICA = FALHA
                                            ├─ docker build → Trivy image ─ CRÍTICA ou segredo = FALHA
                                            ├─ push ECR: togglemaster/<serviço>:v1.2.0-<sha>
                                            └─ GitOps: overlays/develop newTag ──▶ ArgoCD develop

botão promover-staging  ──▶ tag v1.2.0-rc.1 ──▶ promote.yml
                                                 ├─ a tag está num commit da release/v1.2.0?
                                                 ├─ a imagem v1.2.0-<sha> existe no ECR?
                                                 ├─ re-scan com Trivy (CVE nova desde o build?)
                                                 └─ GitOps: overlays/staging ──▶ ArgoCD staging

botão promover-producao ──▶ tag v1.2.0 (mesmo commit do rc) ──▶ promote.yml
                                                 ├─ validações acima + "esse commit foi rc?"
                                                 ├─ aguarda aprovação (Environment production)
                                                 ├─ GitOps: overlays/production ──▶ ArgoCD (janela de deploy)
                                                 └─ abre PR release/v1.2.0 → main
```

**A imagem é construída uma vez só**, no push da release. Staging e production recebem exatamente a mesma imagem que passou por develop.

## Ferramentas de segurança

| Etapa | Ferramenta | Bloqueia quando | Resultado aparece em |
|---|---|---|---|
| SAST | SonarQube Cloud | Quality Gate reprovado | sonarcloud.io e no PR |
| SCA | Snyk (padrão) ou Trivy fs | vulnerabilidade **crítica** em dependência | log do job e aba **Security** do repositório |
| Imagem | Trivy | vulnerabilidade **crítica** ou segredo dentro da imagem | log do job e aba **Security** |
| Pós-deploy | Snyk monitor | não bloqueia; avisa por e-mail se surgir CVE nova | painel do Snyk |

**Plano B do SCA.** A variável `SCA_TOOL` escolhe a ferramenta: `snyk` (padrão) ou `trivy`. Definida na organização, vale para todos os serviços; definida num repositório, vale só para ele (a do repositório tem prioridade). Não precisa de commit para trocar.

## Configuração (uma vez)

### 1. SonarQube Cloud

1. Entre em https://sonarcloud.io com a conta do **GitHub** e importe a organização `FIAP-PosTech-DevOps`. A instalação do app do Sonar na organização exige um admin da org.
2. Crie os 5 projetos, um por repositório de serviço. A chave padrão é `FIAP-PosTech-DevOps_<repositório>`, que é a mesma que a pipeline usa.
3. Em cada projeto: **Administration → Analysis Method → desligue "Automatic Analysis"**. A análise passa a ser feita pela pipeline, com cobertura de testes. Com as duas ligadas, o scanner da CI falha.
4. **My Account → Security → Generate Token**: esse é o `SONAR_TOKEN`.
5. Anote a **chave da organização** no Sonar (algo como `fiap-postech-devops`): ela vai na variável `SONAR_ORGANIZATION`.

### 2. Snyk

1. Entre em https://app.snyk.io com a conta do **GitHub**.
2. **Account settings → Auth Token**: esse é o `SNYK_TOKEN`.

### 3. Token de escrita (`CI_GITHUB_TOKEN`)

A pipeline precisa escrever em dois lugares: o **repositório GitOps** (trocar o `newTag`) e os **repositórios dos serviços e do infra** (criar as branches e tags dos botões de release). O `GITHUB_TOKEN` automático não serve para os dois casos: ele não escreve em outro repositório, e as tags criadas com ele não disparam outros workflows.

Crie um **fine-grained personal access token** em https://github.com/settings/personal-access-tokens:

- **Resource owner:** `FIAP-PosTech-DevOps`. A organização precisa permitir fine-grained tokens e pode exigir aprovação de um admin.
- **Repositories:** só os 7 do projeto (5 serviços, `toggle-master-infra` e `toggle-master-gitops`).
- **Permissions:**
  - Contents: **Read and write**
  - Workflows: **Read and write** (para criar branches que contêm `.github/workflows`)
- **Expiration:** até a data de entrega.

Numa empresa, o equivalente mais robusto é um **GitHub App** da organização, que não fica atrelado à conta de uma pessoa.

### 4. Secrets e variáveis da organização

**Organização → Settings → Secrets and variables → Actions**:

| Tipo | Nome | Valor |
|---|---|---|
| Secret | `SONAR_TOKEN` | token do SonarQube Cloud |
| Secret | `SNYK_TOKEN` | token do Snyk |
| Secret | `CI_GITHUB_TOKEN` | o fine-grained token do passo 3 |
| Variable | `AWS_ACCOUNT_ID` | número da conta AWS (12 dígitos; não é segredo) |
| Variable | `SONAR_ORGANIZATION` | chave da organização no Sonar |
| Variable | `SCA_TOOL` | opcional: `snyk` ou `trivy` |

Na criação, a visibilidade **"Public repositories"** basta enquanto os repositórios forem públicos. Se algum virar privado, troque para *All repositories* ou *Selected repositories*, ou ele deixa de enxergar o valor.

Se o plano da organização não permitir secrets de organização para repositórios públicos, cadastre os mesmos nomes em cada repositório.

### 5. Environments e permissões nos repositórios

Em **cada repositório de serviço**:

- **Settings → Environments → New environment** `production` → marque **Required reviewers** (você). O deploy em produção passa a esperar uma aprovação. `staging` é criado automaticamente na primeira promoção.
- **Settings → Actions → General → Workflow permissions** → marque **Allow GitHub Actions to create and approve pull requests**, para o PR automático release → main depois de produção.

No `toggle-master-infra`, os Environments são `develop`, `staging` e `production` (ver `terraform/README.md`).

### 6. Proteções recomendadas (rulesets)

- `main`: só via PR, com os checks da pipeline passando.
- tags `v*`: ninguém apaga nem move. Uma versão publicada é imutável, como a imagem no ECR.

### 7. Primeira entrada dos workflows na `main` (uma vez por repositório)

O fluxo normal é `feature/*` → `release/*`, mas os botões de release só aparecem na aba **Actions** quando o `release.yml` já está na branch padrão (o GitHub só lista workflows manuais da `main`). Por isso, na primeira vez, cada repositório recebe os workflows por um **PR direto para a `main`**:

1. `toggle-master-infra` primeiro: os serviços chamam os reutilizáveis em `@main`, então eles precisam estar lá antes de qualquer pipeline de serviço rodar. O plan desse PR falha no passo da AWS até o `global` ser aplicado; é esperado.
2. Os 5 serviços depois, **só com os passos 1 a 5 feitos**. O PR já roda build, testes e scans, e falharia sem `SONAR_TOKEN`, `SNYK_TOKEN` e as variáveis.

Use **Squash and merge** e mantenha a branch de origem. Daqui em diante, nenhuma mudança vai direto para a `main`.

## Uso no dia a dia

1. **Abrir uma release:** Actions → **release** → Run workflow → `criar-release` (`minor` para funcionalidade nova, `patch` para correção). A release nasce da `main`.
2. **Desenvolver:** branch `feature/...` ou `fix/...` a partir da release, e PR para `release/vX.Y.Z`. O PR roda os testes e os scans; o merge publica a imagem e sobe em develop.
3. **Promover para staging:** botão `promover-staging`. Corrigiu algo na release? Rode de novo e saem `rc.2`, `rc.3`...
4. **Promover para produção:** botão `promover-producao`. Aprove no Environment; o ArgoCD aplica dentro da janela de deploy.

**Tirar uma demanda do pacote:** `git revert -m 1 <merge da demanda>` na release + novo `promover-staging`.
**Rollback em produção:** `git revert` do commit `deploy(<serviço>): production ...` no repositório GitOps.

## Roteiro para o vídeo (pipeline falhando no passo de segurança)

| Demonstração | Como provocar | O que aparece |
|---|---|---|
| Dependência vulnerável (SCA) | num serviço Python, trocar no `requirements.txt` para uma versão antiga com CVE crítica conhecida e abrir PR | job **SCA** vermelho, com a CVE e a versão corrigida; volte a versão e o job fica verde |
| Código inseguro (SAST) | inserir uma senha fixa ou um SQL montado por concatenação e abrir PR | **Quality Gate failed** no Sonar e no PR |
| Imagem vulnerável (container) | no Dockerfile, trocar a imagem base por uma antiga, por exemplo `python:3.8-slim` | job **Imagem** vermelho; nada é publicado no ECR |

Confira antes da gravação qual versão antiga gera de fato uma vulnerabilidade **crítica** (no snyk.io/vuln ou rodando `trivy image` localmente): a severidade das CVEs muda com o tempo.
