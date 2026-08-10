# Kubernetes — manifestos e scripts de deploy

> O passo a passo de execução está no [README principal](../README.md), seções 4 (construir), 5 (testes) e 6 (escalabilidade). Este documento cobre o conteúdo dos manifestos e o funcionamento dos scripts.

```
k8s/
├── 01-configmap.yaml          endpoints AWS (template, preenchido pelo deploy.sh)
├── 02..06-*.yaml              Deployment + Service dos 5 microsserviços
├── 07-ingress.yaml            rotas públicas
├── 08-hpa-evaluation.yaml     HPA por CPU
├── 09-keda-analytics.yaml     TriggerAuthentication + ScaledObject
├── lib.sh                     funções compartilhadas (use com `source`)
├── env.sh                     carrega as variáveis de sessão (use com `source`)
├── mirror-images.sh           espelha imagens de terceiros para o ECR
├── build-and-push.sh          build e push — todos ou serviços específicos
├── deploy-service.sh          deploy de UM serviço, isolado
├── bootstrap-apikey.sh        gera a SERVICE_API_KEY
├── deploy.sh                  deploy completo (orquestra os anteriores)
└── destroy.sh                 remove a aplicação na ordem correta
```

Os manifestos usam placeholders `${ECR_REGISTRY}`, `${IMAGE_TAG}`, `${SQS_QUEUE_URL}` e afins, substituídos por `envsubst` dentro do `deploy.sh`. **Não aplique com `kubectl apply -f` direto** — os placeholders iriam literalmente para o cluster.

---

## Scripts

### `env.sh`

```bash
source $INFRA/k8s/env.sh
```

Define `CLUSTER`, `ECR`, `QUEUE`, `TABLE`, `REDIS`, `NLB` e `MASTER_KEY` lendo os outputs do Terraform e o cluster ao vivo — nenhum desses valores é fixo entre ciclos.

Precisa ser carregado com `source`: executado como `./env.sh`, roda num subshell e as variáveis somem junto. O script detecta isso e recusa.

Quando alguma variável fica vazia, ele aponta a causa provável em vez de deixar você descobrir depois, com um `curl` retornando página de erro. A `MASTER_KEY` é exibida truncada, para não ficar registrada inteira no histórico do terminal.

### `mirror-images.sh [versão-keda]`

Espelha para o ECR privado as imagens cujo upstream exigiria credencial para pull-through cache: as 3 do KEDA (ghcr.io) e as bases dos Dockerfiles mais os utilitários (Docker Hub).

Roda **depois** do `terraform apply` do `infra` e **antes** do `cluster-addons`. Precisa ser reexecutado a cada ciclo, porque o `destroy` remove os repositórios — a menos que você os preserve (ver README principal, 7.3).

### `lib.sh`

Funções compartilhadas por todos os scripts de deploy, carregadas com `source`. Concentra o que seria duplicado: leitura dos outputs do Terraform, montagem das `DATABASE_URL` com percent-encoding, criação idempotente de Secrets, carga de schema e a lógica de rollout.

Também guarda os mapeamentos serviço → manifesto, serviço → autoscaler e serviço → banco, que são a base do deploy isolado.

### `build-and-push.sh [tag] [serviço...]`

```bash
./build-and-push.sh v1                            # todos os 5
./build-and-push.sh v2 flag-service               # só um
./build-and-push.sh v2 flag-service auth-service  # alguns
./build-and-push.sh $(git rev-parse --short HEAD) # tag pelo commit
```

Passa `--build-arg BASE_REGISTRY=<ecr>/mirror/library`, fazendo o build puxar `golang`, `alpine` e `python` do espelho em vez do Docker Hub. Usa `--platform linux/amd64` explicitamente, para não gerar imagem arm64 num Mac com Apple Silicon.

Os repositórios são IMMUTABLE: repetir a mesma tag falha de propósito.

### `deploy-service.sh <serviço...> [tag] [--with-schema]`

Deploy de **um ou mais** serviços, sem tocar nos demais. É o caminho para o cenário real de corrigir um bug e subir só o que mudou.

```bash
./deploy-service.sh flag-service v3
./deploy-service.sh flag-service targeting-service v3
./deploy-service.sh auth-service v2 --with-schema
./deploy-service.sh evaluation-service $(git rev-parse --short HEAD)
./deploy-service.sh --help
```

**A ordem dos argumentos é livre.** Nomes de serviço são reconhecidos pela lista conhecida; o argumento restante vira a tag. `v3 flag-service` e `flag-service v3` são equivalentes. Passar duas tags é rejeitado como ambíguo.

Com vários serviços, ele **reordena por dependência** — o auth-service sempre primeiro, porque o evaluation-service depende da `SERVICE_API_KEY` validada por ele. Duplicatas são removidas.

O que ele faz por serviço:

1. **Confere se a imagem existe no ECR** — evita subir um Deployment que ficaria em `ImagePullBackOff`
2. Atualiza somente o Secret daquele serviço
3. Aplica o manifesto e, quando houver, o autoscaler que o acompanha
4. `rollout restart` + `rollout status`

E uma vez só, no início: lê os outputs do Terraform e cria o ConfigMap **apenas se estiver faltando** — num deploy isolado não se reescreve configuração compartilhada.

Ao final imprime as imagens em uso e os comandos de rollback. Com mais de um serviço, ou quando algo falha, mostra um resumo com ✓ e ✗ por serviço — assim você sabe exatamente onde parou, mesmo se o terceiro de cinco quebrar.

**O que ele não faz:** schemas (a menos que você passe `--with-schema`), Ingress e ConfigMap já existente. Esses são compartilhados e ficam no `deploy.sh`.

Diferenças de comportamento frente ao deploy completo:

| | `deploy.sh` | `deploy-service.sh` |
|---|---|---|
| `MASTER_KEY` | preservada se já existir | preservada se já existir |
| `SERVICE_API_KEY` | sempre regenerada (`--force`) | preservada; só cria se faltar |
| Schemas | sempre carregados | só com `--with-schema` |
| Ingress | aplicado | não tocado |

### `bootstrap-apikey.sh [--force]`

Cria a `SERVICE_API_KEY` no auth-service e grava no Secret do evaluation-service, reiniciando-o para carregar o valor novo.

Sem `--force`, não faz nada se a chave já existir. Útil para rotacionar a credencial de serviço sem redeploy completo.

Precisa do auth-service no ar — usa `port-forward` em vez do NLB, então funciona mesmo antes do Ingress existir.

### `deploy.sh [tag]`

Orquestrador do deploy completo. Cuida do que é **compartilhado** e delega cada serviço ao `deploy-service.sh`:

1. Lê os outputs do Terraform
2. Carrega os 3 `init.sql` a partir de um pod temporário (o RDS não é acessível pela internet)
3. Aplica o ConfigMap
4. Sobe o auth-service
5. Gera a `SERVICE_API_KEY` com `--force`
6. Sobe os outros 4 serviços
7. Aplica o Ingress

**Por que o auth-service vem primeiro.** A tabela `api_keys` nasce vazia — o `init.sql` cria a estrutura, não insere chave nenhuma. O `evaluation-service` precisa de uma chave válida para chamar flag e targeting, que a validam contra o auth-service. A chave só pode ser criada com o auth-service já no ar; subir tudo de uma vez daria `401` em toda avaliação.

**É seguro rodar mais de uma vez.** Os `init.sql` usam `CREATE TABLE IF NOT EXISTS`; os Secrets usam `--dry-run=client | kubectl apply`; e há um `rollout restart` antes de cada espera — necessário porque `envFrom` resolve as variáveis na criação do pod e **não** recarrega quando o Secret muda. Sem o restart, corrigir um Secret e rodar de novo não teria efeito.

A `MASTER_KEY` é gerada na primeira execução e **preservada** nas seguintes, para não invalidar a que você já tem em uso. Ela fica no Secret e é recuperada pelo `env.sh`.

### `destroy.sh`

Remove a aplicação na ordem correta, **antes** do `terraform destroy` do `cluster-addons`.

O ponto crítico é o KEDA: o `helm uninstall` apaga os CRDs, e para apagar um CRD o Kubernetes precisa remover todos os recursos daquele tipo. O `ScaledObject` e o `TriggerAuthentication` têm finalizers que só o operador do KEDA sabe liberar — se o operador for embora primeiro, ninguém libera e o destroy trava com `context deadline exceeded`.

O script remove esses recursos com o operador ainda vivo, e tem uma rede de segurança que libera finalizers manualmente caso algo já esteja preso em `Terminating`.

Ele **não** apaga o namespace nem as Service Accounts: esses pertencem ao módulo `cluster-addons` e removê-los aqui deixaria o state do Terraform inconsistente.

---

## Decisões nos manifestos

### Requests dimensionados por linguagem

Binário Go consome 10-20Mi; Python com gunicorn, 60-120Mi. Requests uniformes desperdiçariam a capacidade que o HPA e o KEDA precisam para escalar.

| Serviço | CPU req | Mem req | Mem limit |
|---|---|---|---|
| auth-service | 50m | 32Mi | 64Mi |
| flag-service | 100m | 96Mi | 192Mi |
| targeting-service | 100m | 96Mi | 192Mi |
| evaluation-service | 100m | 64Mi | 128Mi |
| analytics-service | 100m | 128Mi | 256Mi |

O request de CPU do `evaluation-service` é a base do cálculo do HPA: com alvo de 70%, ele escala quando o uso médio passa de ~70m por pod.

### `runAsUser: 1000` no nível do Pod

Os Dockerfiles Go não declaram `USER`, então rodariam como root e `runAsNonRoot: true` bloquearia o pod com `CreateContainerConfigError`. Definir `runAsUser` no Pod força o uid sem exigir alteração da imagem. Os Dockerfiles Python já criam um usuário com uid 1000, então ficam consistentes.

### `emptyDir` em `/tmp`

Com `readOnlyRootFilesystem: true`, o gunicorn não conseguiria escrever seus arquivos temporários de worker. O volume resolve sem abrir o filesystem inteiro para escrita.

### Ingress sem `rewrite-target`

As rotas usam os caminhos reais de cada serviço, conferidos no código-fonte:

| Rota | Serviço |
|---|---|
| `/validate`, `/admin` | auth-service |
| `/flags` | flag-service |
| `/rules` | targeting-service |
| `/evaluate` | evaluation-service |

O `analytics-service` não tem rota pública — só consome a fila.

### Sem Secret no analytics-service

Ele não usa senha nenhuma: o acesso ao SQS e ao DynamoDB vem por IRSA, e os endpoints vêm do ConfigMap. O ConfigMap também **não** define `AWS_ENDPOINT_URL` — essa variável existe só para apontar o boto3 ao LocalStack no ambiente local. Ausente, o SDK usa os endpoints reais.

### HPA com janelas assimétricas

`stabilizationWindowSeconds: 15` na subida (reação rápida, boa para demonstração) e `120` na descida (evita oscilação quando a carga varia).

### KEDA com `minReplicaCount: 0`

Scale-to-zero: sem mensagem na fila, nenhum pod rodando. É o comportamento que o HPA por CPU não consegue reproduzir, e o argumento central para usar KEDA neste serviço — a fila pode acumular centenas de mensagens com a CPU baixa, porque o worker fica bloqueado em I/O no `receive_message`.

---

## Observações sobre o código da aplicação

Detalhes conferidos no código-fonte que afetam os testes:

- **`/evaluate` usa query parameters**, não corpo JSON: `?user_id=x&flag_name=y`
- **`/evaluate` não exige autenticação**; os demais endpoints sim
- **Só `PERCENTAGE` está implementado** no `evaluator.go`. O `USER_LIST` aparece como exemplo no `init.sql` mas cai no `return false`
- **O resultado é determinístico**: `sha1(user_id + flag_name)`, primeiros 4 bytes, módulo 100, comparado com a porcentagem
- **Cache de 30 segundos** no Redis: ao alterar uma regra, espere o TTL antes de testar
- **`api_keys` nasce vazia** — daí o bootstrap em duas fases do `deploy.sh`

---

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| `ImagePullBackOff` | faltou `mirror-images.sh`/`build-and-push.sh`, ou a tag não existe |
| `exec format error` | imagem arm64 em nó amd64 |
| `CreateContainerConfigError` | Secret ou ConfigMap ausente — rode o `deploy.sh` inteiro |
| `invalid port ... after host` | senha do RDS sem percent-encoding |
| evaluation-service com `401` | `SERVICE_API_KEY` inválida, bootstrap falhou |
| `AccessDenied` da AWS | Deployment sem `serviceAccountName` |
| HPA com `TARGETS <unknown>` | metrics-server ainda coletando, ou ausente |
| ScaledObject sem escalar | `kubectl logs -n keda deploy/keda-operator` |
| pods do KEDA em `ContainerCreating` eterno | esperando o secret `kedaorg-certs`, que o operator cria — verifique o operator primeiro |
