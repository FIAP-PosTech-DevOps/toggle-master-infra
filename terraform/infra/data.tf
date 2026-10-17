# Account ID da conta autenticada — evita hardcodar o número em ARNs.
data "aws_caller_identity" "current" {}

# Role da EC2 do laboratório Backstage (stack global). O data source de LISTA
# não falha quando a role não existe: devolve vazio. Assim os ambientes sobem
# com ou sem o global atualizado.
data "aws_iam_roles" "backstage" {
  name_regex = "^${var.project_name}-backstage$"
}
