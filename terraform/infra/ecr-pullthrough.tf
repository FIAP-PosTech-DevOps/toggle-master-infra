# Pull-through cache: todo pull de imagem de terceiros passa a ir para o SEU
# ECR privado, que busca do upstream na primeira vez e guarda uma cópia.
#
# Ganhos frente a puxar direto do registro público:
#   - nenhuma dependência de disponibilidade do upstream em runtime
#   - imune a rate limit (Docker Hub limita pulls anônimos)
#   - escaneamento de vulnerabilidade do ECR sobre imagens de terceiros
#   - cópia própria caso a imagem seja removida do upstream
#
# Só criamos regras para os upstreams que NÃO exigem credencial. Docker Hub e
# ghcr.io exigem secret no Secrets Manager; essas imagens são espelhadas pelo
# script k8s/mirror-images.sh.

# registry.k8s.io -> metrics-server e ingress-nginx
resource "aws_ecr_pull_through_cache_rule" "k8s" {
  ecr_repository_prefix = "k8s"
  upstream_registry_url = "registry.k8s.io"
}

# public.ecr.aws -> aws-load-balancer-controller
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

# ---------------------------------------------------------------------------
# Permissão extra para os nós
# ---------------------------------------------------------------------------
# AmazonEC2ContainerRegistryReadOnly não basta para pull-through: o primeiro
# pull de uma imagem ainda não cacheada precisa CRIAR o repositório e IMPORTAR
# a imagem do upstream. Escopamos aos prefixos de cache, então os nós continuam
# sem poder criar repositório fora deles.
data "aws_iam_policy_document" "ecr_pull_through" {
  statement {
    sid    = "PullThroughCache"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${aws_ecr_pull_through_cache_rule.k8s.ecr_repository_prefix}/*",
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix}/*",
    ]
  }
}

resource "aws_iam_policy" "ecr_pull_through" {
  name        = "${local.name_prefix}-ecr-pull-through"
  description = "Permite aos nós popular o cache pull-through do ECR"
  policy      = data.aws_iam_policy_document.ecr_pull_through.json
}
