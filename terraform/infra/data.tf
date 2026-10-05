# Account ID da conta autenticada — evita hardcodar o número em ARNs.
data "aws_caller_identity" "current" {}
