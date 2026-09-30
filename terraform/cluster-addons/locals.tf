locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "${local.name_prefix}-cluster"

  account_id = data.aws_caller_identity.current.account_id

  # A VPC vem do próprio cluster, não de uma variável.
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id

  # Registry compartilhado (stack global), que pode estar em outra região.
  ecr_registry = "${local.account_id}.dkr.ecr.${var.ecr_region}.amazonaws.com"

  # Prefixos de pull-through criados no stack global. Uma imagem de
  # registry.k8s.io/metrics-server/metrics-server passa a vir de
  # <ecr_registry>/k8s/metrics-server/metrics-server.
  registry_k8s        = "${local.ecr_registry}/k8s"
  registry_ecr_public = "${local.ecr_registry}/ecr-public"

  # ARNs das roles IRSA pela mesma convenção de nomes do módulo
  # workload-identity (stack infra). Evita ler o state do outro stack.
  irsa_role_arns = {
    alb_controller = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-alb-controller"
    keda           = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-keda"
    openbao        = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-openbao"
  }

  openbao_unseal_kms_alias = "alias/${local.name_prefix}-openbao-unseal"
}
