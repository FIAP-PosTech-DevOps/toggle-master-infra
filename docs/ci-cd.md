# CI/CD e DevSecOps dos microsserviços

As pipelines dos 5 serviços são **workflows reutilizáveis** que ficam neste repositório. Cada serviço tem três arquivos curtos em `.github/workflows/` que só chamam estes:

| Neste repositório | Chamado por (em cada serviço) | Papel |
|---|---|---|
| `.github/workflows/service-ci.yml` | `ci.yml` | build, testes, lint, SAST, SCA, imagem, ECR e deploy em develop (botão) ou staging (release) |
| `.github/workflows/service-promote.yml` | `promote.yml` | production no merge do PR release → main, com a mesma imagem de staging |
| `.github/workflows/git-release.yml` | `release.yml` (e o `release.yml` daqui) | botão `criar-release` |
| `.github/actions/gitops-set-image` | os dois primeiros | commit do `newTag` no repositório GitOps |

Uma melhoria na pipeline, como trocar a versão do Trivy, é feita aqui uma vez e vale para os 5 serviços.

## Fluxo completo

Três ambientes, um gatilho para cada:

| Ambiente | Como chega lá | Imagem |
|---|---|---|
| **develop** | botão **Actions → ci → Run workflow**, escolhendo **qualquer branch** em "Use workflow from" | `dev-<branch>-<sha>` (construída a cada clique) |
| **staging** | push em `release/vX.Y.Z`, ou seja, o merge de cada PR de feature no pacote | `vX.Y.Z-<sha>` (construída a cada push) |
| **production** | merge do PR `release/vX.Y.Z` → `main`, com aprovação | a **mesma** `vX.Y.Z-<sha>` que está em staging, sem novo build |

```
feature/x ──botão Run workflow──▶ ci.yml (branch feature/x)
                                   ├─ build + testes (go test | pytest)
                                   ├─ lint (golangci-lint | flake8)
                                   ├─ SAST: SonarQube Cloud ── Quality Gate reprovado = FALHA
                                   ├─ SCA: Snyk (ou Trivy fs) ─ vulnerabilidade CRÍTICA = FALHA
                                   ├─ docker build → Trivy image ─ CRÍTICA ou segredo = FALHA
                                   ├─ push ECR: togglemaster/<serviço>:dev-feature-x-<sha>
                                   └─ GitOps: overlays/develop newTag ──▶ ArgoCD develop

feature/x ──PR──▶ release/v1.2.0 ──push──▶ ci.yml
                                            ├─ as mesmas etapas acima
                                            ├─ push ECR: togglemaster/<serviço>:v1.2.0-<sha>
                                            └─ GitOps: overlays/staging newTag ──▶ ArgoCD staging

release/v1.2.0 ──PR + merge──▶ main ──▶ promote.yml
                                         ├─ aguarda aprovação (Environment production)
                                         ├─ a imagem v1.2.0-<sha> (último commit da release) existe no ECR?
                                         ├─ é a mesma que está no overlay de staging?
                                         ├─ re-scan com Trivy (CVE nova desde o build?)
                                         ├─ GitOps: overlays/production ──▶ ArgoCD (janela de deploy)
                                         └─ tag v1.2.0 no commit da main
```

**A imagem de uma versão é construída uma vez só**, no push da release. Production recebe exatamente a imagem que está rodando em staging. O SHA vem do PR (o último commit da release), então o fluxo funciona com **Squash and merge**: o commit novo da main é outro, mas a imagem é a da release.

**O develop é compartilhado.** Cada clique no botão substitui o que estava lá. Antes de subir a sua branch, combine com o time; o último commit `deploy(<serviço>): develop ...` no repositório GitOps mostra qual branch está no ambiente.

**PR não publica nada.** PR para `release/*` ou para a `main` roda build, testes e todos os scans, e só.

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

- **Settings → Environments → New environment** `production` → marque **Required reviewers** (você). O deploy em produção passa a esperar uma aprovação. `develop` e `staging` são criados automaticamente no primeiro deploy.
- Os três Environments também liberam a publicação no ECR: a role `togglemaster-gha-ecr-push` só confia em jobs que rodam dentro deles (o `sub` do token OIDC traz `environment:<nome>`). Um job fora deles, em qualquer branch, não recebe credencial da AWS.

No `toggle-master-infra`, os Environments são `develop`, `staging` e `production` (ver `terraform/README.md`).

### 6. Proteções recomendadas (rulesets)

- `main`: só via PR, com os checks da pipeline passando.
- tags `v*`: ninguém apaga nem move. Uma versão publicada é imutável, como a imagem no ECR.

### 7. Primeira entrada dos workflows na `main` (uma vez por repositório)

O fluxo normal é `feature/*` → `release/*` → `main`, mas os botões (**Run workflow** do `ci.yml` e o `release.yml`) só aparecem na aba **Actions** quando o workflow já está na branch padrão (o GitHub só lista workflows manuais da `main`). Por isso, na primeira vez, e também quando a própria estratégia da pipeline muda, cada repositório recebe os workflows por um **PR direto para a `main`**:

1. `toggle-master-infra` primeiro: os serviços chamam os reutilizáveis em `@main`, então eles precisam estar lá antes de qualquer pipeline de serviço rodar. O plan desse PR falha no passo da AWS até o `global` ser aplicado; é esperado.
2. Os 5 serviços depois, **só com os passos 1 a 5 feitos**. O PR já roda build, testes e scans, e falharia sem `SONAR_TOKEN`, `SNYK_TOKEN` e as variáveis.

Use **Squash and merge** e mantenha a branch de origem. Daqui em diante, nenhuma mudança vai direto para a `main`.

## Uso no dia a dia

1. **Abrir uma release:** Actions → **release** → Run workflow → `minor` para funcionalidade nova, `patch` para correção, `major` para quebra de contrato. A `release/vX.Y.Z` nasce da `main`.
2. **Desenvolver:** branch `feature/...` ou `fix/...` a partir da release.
3. **Testar em develop:** Actions → **ci** → Run workflow → em "Use workflow from" escolha a sua branch. A esteira roda os testes e os scans e sobe a branch em develop.
4. **Entrar no pacote (staging):** PR da feature para `release/vX.Y.Z`. O PR roda os testes e os scans; o merge publica `vX.Y.Z-<sha>` e sobe em staging.
5. **Produção:** validado em staging, abra o PR `release/vX.Y.Z` → `main` e faça o merge (**Squash and merge**, mantendo a branch). Aprove no Environment `production`; o ArgoCD aplica dentro da janela de deploy, e a tag `vX.Y.Z` é criada na main.

**Tirar uma demanda do pacote:** `git revert <commit da demanda>` na release (com squash, a demanda é um commit só). O push sobe a release sem ela em staging.
**Hotfix:** `criar-release` com `patch`, PR do `fix/...` para a release nova, valide em staging e faça o merge na main.
**Rollback em produção:** `git revert` do commit `deploy(<serviço>): production ...` no repositório GitOps.

## Roteiro para o vídeo (pipeline falhando no passo de segurança)

| Demonstração | Como provocar | O que aparece |
|---|---|---|
| Dependência vulnerável (SCA) | num serviço Python, trocar no `requirements.txt` para uma versão antiga com CVE crítica conhecida e abrir PR | job **SCA** vermelho, com a CVE e a versão corrigida; volte a versão e o job fica verde |
| Código inseguro (SAST) | inserir uma senha fixa ou um SQL montado por concatenação e abrir PR | **Quality Gate failed** no Sonar e no PR |
| Imagem vulnerável (container) | no Dockerfile, trocar a imagem base por uma antiga, por exemplo `python:3.8-slim` | job **Imagem** vermelho; nada é publicado no ECR |

Confira antes da gravação qual versão antiga gera de fato uma vulnerabilidade **crítica** (no snyk.io/vuln ou rodando `trivy image` localmente): a severidade das CVEs muda com o tempo.
