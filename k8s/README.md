# Kubernetes — manifestos e scripts de deploy

> O passo a passo de execução está no [README principal](../README.md), seções 4 (construir), 5 (testes) e 6 (escalabilidade). Este documento cobre o conteúdo dos manifestos e o funcionamento dos scripts.

```
k8s/
├── 01-configmap.yaml          endpoints AWS (template, preenchido pelo deploy.sh)
├── 02..06-*.yaml              Deployment + Service dos 5 microsserviços
├── 07-ingress.yaml            rotas públicas
├── 08-hpa-evaluation.yaml     HPA por CPU
├── 09-keda-analytics.yaml     TriggerAuthentication + ScaledObject
├── env.sh                     carrega as variáveis de sessão (use com `source`)
├── mirror-images.sh           espelha imagens de terceiros para o ECR
├── build-and-push.sh          build e push das 5 imagens da aplicação
├── deploy.sh                  deploy completo
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

### `build-and-push.sh [tag]`

Build das 5 imagens e push para o ECR. Passa `--build-arg BASE_REGISTRY=<ecr>/mirror/library`, fazendo o build puxar `golang`, `alpine` e `python` do espelho em vez do Docker Hub. Usa `--platform linux/amd64` explicitamente, para não gerar imagem arm64 se você estiver num Mac com Apple Silicon.

Os repositórios são IMMUTABLE: repetir a mesma tag falha de propósito.

### `deploy.sh [tag]`

1. Lê os outputs do Terraform — endpoints, URL da fila, registry
2. Busca as senhas no Secrets Manager e monta as `DATABASE_URL` com `sslmode=require`
3. Carrega os 3 `init.sql` a partir de um pod temporário (o RDS não é acessível pela internet)
4. Cria ConfigMap e Secrets
5. Sobe o auth-service e espera ficar pronto
6. Cria a `SERVICE_API_KEY` via `POST /admin/keys`
7. Sobe os outros 4 serviços, Ingress, HPA e ScaledObject

**Por que duas fases.** A tabela `api_keys` nasce vazia — o `init.sql` cria a estrutura, não insere chave nenhuma. O `evaluation-service` precisa de uma chave válida para chamar flag e targeting, que a validam contra o auth-service. A chave só pode ser criada com o auth-service já no ar. Subir tudo de uma vez daria `401` em toda avaliação.

O script gera uma `MASTER_KEY` aleatória a cada execução (em vez do `admin-secreto-123` do compose) e a imprime no final.

**É seguro rodar mais de uma vez.** Os `init.sql` usam `CREATE TABLE IF NOT EXISTS`; os Secrets usam `--dry-run=client | kubectl apply`; e há um `rollout restart` antes de cada espera — necessário porque `envFrom` resolve as variáveis na criação do pod e **não** recarrega quando o Secret muda. Sem o restart, corrigir um Secret e rodar de novo não teria efeito.

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
