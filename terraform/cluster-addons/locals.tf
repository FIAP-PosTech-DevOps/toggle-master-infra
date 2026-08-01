locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "${local.name_prefix}-cluster"

  account_id = data.aws_caller_identity.current.account_id

  # A VPC vem do próprio cluster, não de uma variável — menos coisa para
  # copiar e colar errado.
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id

  # ARNs das roles IRSA derivados da mesma convenção de nomes usada no
  # módulo infra (irsa.tf). Se você renomear as roles lá, ajuste aqui.
  # Host do ECR privado desta conta.
  ecr_registry = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  # Prefixos de pull-through criados no módulo infra. Uma imagem que antes
  # vinha de registry.k8s.io/metrics-server/metrics-server passa a vir de
  # <ecr_registry>/k8s/metrics-server/metrics-server, e o ECR busca do
  # upstream na primeira vez.
  registry_k8s        = "${local.ecr_registry}/k8s"
  registry_ecr_public = "${local.ecr_registry}/ecr-public"

  # Repositórios espelhados manualmente por k8s/mirror-images.sh (upstreams
  # que exigiriam credencial: ghcr.io e Docker Hub).
  registry_mirror = "${local.ecr_registry}/mirror"

  irsa_role_arns = {
    alb_controller = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-alb-controller"
    evaluation     = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-evaluation"
    analytics      = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-analytics"
    keda           = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-irsa-keda"
  }
}
