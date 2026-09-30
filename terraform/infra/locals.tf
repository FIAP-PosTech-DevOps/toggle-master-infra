locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "${local.name_prefix}-cluster"
  account_id   = data.aws_caller_identity.current.account_id

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "toggle-master-infra"
  }

  # Roles do GitHub Actions criadas pelo stack global. Recebem acesso de
  # admin ao cluster para o `plan`/`apply` do cluster-addons (os providers
  # helm/kubernetes falam com a API do Kubernetes).
  ci_role_arns = [
    for name in var.ci_role_names : "arn:aws:iam::${local.account_id}:role/${name}"
  ]

  cluster_admin_principal_arns = distinct(concat(local.ci_role_arns, var.cluster_admin_principal_arns))

  # Registry compartilhado (stack global), normalmente em outra região.
  ecr_registry = "${local.account_id}.dkr.ecr.${var.ecr_region}.amazonaws.com"
}
