# O pull-through cache (stack global) precisa que o nó possa CRIAR o
# repositório de cache e IMPORTAR a imagem do upstream no primeiro pull.
# AmazonEC2ContainerRegistryReadOnly não cobre isso. A permissão fica
# escopada aos prefixos de cache, no registry compartilhado — os nós
# continuam sem poder criar repositório fora deles.
data "aws_iam_policy_document" "ecr_pull_through" {
  statement {
    sid    = "PullThroughCache"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage",
    ]
    resources = [
      for prefix in var.ecr_pull_through_prefixes :
      "arn:aws:ecr:${var.ecr_region}:${local.account_id}:repository/${prefix}/*"
    ]
  }
}

resource "aws_iam_policy" "ecr_pull_through" {
  name        = "${local.name_prefix}-ecr-pull-through"
  description = "Permite aos nos popular o cache pull-through do ECR"
  policy      = data.aws_iam_policy_document.ecr_pull_through.json
}
