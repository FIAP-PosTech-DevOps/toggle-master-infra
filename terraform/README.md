# Terraform — referência dos módulos

> O passo a passo de execução está no [README principal](../README.md), seções 2 (pré-requisitos), 4 (construir) e 7 (destruir). Este documento cobre apenas o que cada módulo faz, suas variáveis e as decisões técnicas.

```
terraform/
├── infra/            1º apply — recursos AWS
└── cluster-addons/   2º apply — o que roda dentro do cluster
```

Os providers `kubernetes` e `helm` precisam de um cluster existente no momento do `plan`. Por isso são dois states, aplicados nesta ordem — e destruídos na ordem inversa.

---

## Módulo `infra`

### O que cria

| Arquivo | Recursos |
|---|---|
| `vpc.tf` | VPC, 2 sub-redes públicas, 2 privadas, IGW, NAT Gateway, route tables |
| `eks.tf` | cluster EKS, managed node group, provedor OIDC |
| `rds.tf` | 3 instâncias PostgreSQL (auth, flags, targeting) + subnet group |
| `elasticache.tf` | replication group Redis de 1 nó |
| `dynamodb.tf` | tabela `ToggleMasterAnalytics`, chave `event_id` |
| `sqs.tf` | fila principal + dead-letter queue |
| `ecr.tf` | 5 repositórios privados, IMMUTABLE, com lifecycle policy |
| `ecr-pullthrough.tf` | regras de cache para `registry.k8s.io` e `public.ecr.aws` |
| `irsa.tf` | 4 roles IRSA (evaluation, analytics, ALB controller, KEDA) |
| `security_groups.tf` | SGs de RDS e Redis, liberados só para o SG dos nós |
| `kms.tf` | CMK para EKS secrets, ECR e RDS |
| `budgets.tf` | alarme de orçamento com alertas em 50%, 80% e previsão de 100% |

### Variáveis que importam

| Variável | Default | Observação |
|---|---|---|
| `alert_email` | — | **obrigatória**, sem default |
| `cluster_version` | `1.30` | **troque**. Versão em extended support custa 6x mais |
| `cluster_endpoint_public_access_cidrs` | `["0.0.0.0/0"]` | restrinja ao seu IP `/32` |
| `node_instance_types` | `["c7i-flex.large"]` | limitado pelo free plan da conta |
| `node_capacity_type` | `ON_DEMAND` | `SPOT` economiza ~60%, com risco de interrupção |
| `single_nat_gateway` | `true` | `false` = 1 por AZ, ~US$32/mês a mais |
| `databases` | 3 entradas | mapa `sufixo → nome do banco` |

Demais variáveis em `infra/variables.tf`, todas documentadas.

### Outputs

Consumidos pelos scripts em `../k8s`:

```bash
terraform output ecr_registry                  # host para docker login
terraform output rds_endpoints                 # mapa serviço → host:porta
terraform output rds_master_user_secret_arns   # ARNs no Secrets Manager
terraform output redis_endpoint
terraform output sqs_queue_url
terraform output dynamodb_table_name
terraform output irsa_role_arns
```

As senhas do RDS **não** aparecem em output. `manage_master_user_password = true` faz o próprio RDS gerar e guardar no Secrets Manager:

```bash
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -json rds_master_user_secret_arns | jq -r .auth) \
  --query SecretString --output text | jq -r .password
```

### Decisões

**Módulos oficiais para VPC e EKS.** `terraform-aws-modules/vpc` e `/eks` em vez de recursos soltos: a malha de sub-redes, route tables e a configuração do OIDC têm muitos detalhes fáceis de errar.

**`default_tags` no provider.** Todo recurso recebe `Project`, `Environment` e `ManagedBy` automaticamente, inclusive os criados dentro dos módulos. Nenhum recurso repete `tags`. É o que permite a varredura por tag na verificação de destroy.

**Módulo oficial de IRSA.** `iam-role-for-service-accounts-eks` monta a trust policy do OIDC corretamente — o `sub` precisa casar exatamente com `namespace:serviceaccount`, e errar isso gera um `AccessDenied` difícil de rastrear.

**Pull-through cache com IAM escopado.** Os nós ganham `ecr:CreateRepository` e `ecr:BatchImportUpstreamImage`, mas restritas aos prefixos `k8s/*` e `ecr-public/*`.

---

## Módulo `cluster-addons`

### O que instala

| Arquivo | Componente |
|---|---|
| `metrics-server.tf` | metrics-server — pré-requisito do HPA |
| `alb-controller.tf` | aws-load-balancer-controller, com IRSA |
| `ingress-nginx.tf` | ingress-nginx exposto por NLB |
| `keda.tf` | KEDA, com IRSA na SA do operador |
| `namespace.tf` | namespace `togglemaster` + Service Accounts anotadas |

### Não precisa de tfvars

O módulo descobre tudo sozinho: o cluster pelo nome derivado de `project_name` + `environment`, a VPC pelo data source do cluster, e os ARNs das roles IRSA pela convenção de nomes do `infra`.

A exceção são as versões dos charts. Descubra as compatíveis com:

```bash
./check-chart-versions.sh 1.36
```

O script mostra a última versão de cada chart e a restrição `kubeVersion` declarada. Se algum default estiver defasado, sobrescreva no `terraform.tfvars`:

```hcl
metrics_server_chart_version = "3.13.1"
alb_controller_chart_version = "3.4.3"
ingress_nginx_chart_version  = "4.15.1"
keda_chart_version           = "2.20.1"
```

### Armadilhas conhecidas

**Webhook do ALB controller intercepta todo Service do cluster.** Enquanto seus pods não estão `Ready`, qualquer Service novo falha com `no endpoints available for service aws-load-balancer-webhook-service`. Por isso `metrics-server`, `ingress-nginx` e `keda` têm `depends_on` apontando para ele, e o release do controller usa `wait = true`.

**Upgrade do ALB controller quebra o TLS do webhook.** O chart gera um certificado auto-assinado na instalação; num `helm upgrade` ele regenera o par, mas os pods continuam servindo o certificado antigo. O sintoma é `x509: certificate signed by unknown authority`. Correção:

```bash
kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system
```

Só acontece em upgrade, nunca em instalação limpa.

**Cada chart estrutura o endereço da imagem de um jeito.**

| Chart | Estrutura |
|---|---|
| metrics-server | `image.repository` = endereço completo |
| ALB controller | `image.repository` = endereço completo |
| ingress-nginx | `image.registry` (host) + `image.image` (caminho) |
| KEDA | `global.image.registry` + `image.<componente>.repository` |

O Helm **não valida** chaves: um `--set` inexistente é ignorado em silêncio. Sempre renderize antes de aplicar:

```bash
helm template keda kedacore/keda --version 2.20.1 \
  --set global.image.registry=<seu-ecr> \
  --set image.keda.repository=mirror/kedacore/keda | grep "image:"
```

**KEDA usa a SA do operador, não a do workload.** Com `identityOwner: keda`, quem chama o SQS é o pod do `keda-operator` no namespace `keda`. A role IRSA confia em `keda:keda-operator`, e o chart anota essa SA via `podIdentity.aws.irsa.roleArn`. Uma Service Account no namespace da aplicação não teria efeito nenhum.

**`kubernetes_manifest` não serve para CRDs recém-criados.** O `TriggerAuthentication` e o `ScaledObject` do KEDA ficam como manifestos `kubectl` em `../k8s`, porque o `kubernetes_manifest` exige o schema do CRD registrado já no `plan` — e ele só nasce quando o `helm_release` roda.

---

## Estado remoto

Por padrão o state é local, o que serve para um laboratório individual. Para compartilhar com o grupo, veja `infra/backend.tf.example` (bucket S3 + tabela de lock) e descomente o bloco `backend "s3"` no `versions.tf` de cada módulo.

O `.gitignore` bloqueia state e tfvars. O `.terraform.lock.hcl`, ao contrário, **deve** ser commitado — ele fixa os hashes das versões de provider para todo mundo.
