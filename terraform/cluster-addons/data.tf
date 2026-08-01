data "aws_caller_identity" "current" {}

# Lê o cluster criado pelo módulo infra. É daqui que saem o endpoint e o CA
# usados pelos providers kubernetes/helm.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# Token de autenticação de curta duração (equivalente ao que o
# `aws eks get-token` gera).
data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}
