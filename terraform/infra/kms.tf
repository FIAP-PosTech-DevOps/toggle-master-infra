# Uma única CMK para os dados em repouso que exigem chave gerenciada por nós:
# Secrets do etcd (EKS), imagens no ECR e volumes do RDS.
#
# DynamoDB e SQS ficam com a criptografia padrão da AWS (chave gerenciada pelo
# serviço, sem custo) — já é criptografia em repouso, e evita cobrança de
# requisições KMS num serviço que recebe muitas escritas.
resource "aws_kms_key" "main" {
  description             = "${local.name_prefix} - EKS secrets, ECR e RDS"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
