# CMK do ambiente para os dados em repouso que exigem chave gerenciada por
# nós: Secrets do etcd (EKS), volumes do RDS e o Redis.
#
# DynamoDB e SQS ficam com a criptografia padrão da AWS (sem custo por
# requisição). O ECR tem a própria chave, no stack global.
resource "aws_kms_key" "main" {
  description             = "${local.name_prefix} - EKS secrets, RDS e ElastiCache"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.main_key.json
}

# Policy explícita (igual à padrão da AWS): a conta administra a chave e o
# acesso de cada serviço/role é concedido por IAM. Deixar implícito funciona,
# mas esconde de quem lê o código quem pode usar a chave.
data "aws_iam_policy_document" "main_key" {
  # Key policy: "Resource = *" aqui significa "esta chave" (padrão da AWS).
  #checkov:skip=CKV_AWS_109:key policy padrao da conta
  #checkov:skip=CKV_AWS_111:key policy padrao da conta
  #checkov:skip=CKV_AWS_356:key policy padrao da conta
  statement {
    sid       = "EnableAccountIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
