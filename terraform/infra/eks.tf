module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id = module.vpc.vpc_id
  # Nós ficam só nas sub-redes privadas: nenhum nó recebe IP público.
  subnet_ids = module.vpc.private_subnets

  # Endpoint privado sempre ligado (tráfego dentro da VPC). O público fica
  # ligado só para você conseguir rodar kubectl do seu notebook — restrinja
  # ao seu IP em cluster_endpoint_public_access_cidrs.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # Secrets do etcd criptografados com a nossa CMK (envelope encryption).
  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.main.arn
  }

  # Quem roda o terraform apply vira cluster-admin automaticamente, sem
  # precisar editar o ConfigMap aws-auth na mão.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Cria o provedor OIDC do cluster no IAM — é o que torna o IRSA possível.
  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      # Permissões do nó, ambas restritas a puxar imagem:
      #  - ecr_read_only:   ler qualquer repositório do ECR
      #  - ecr_pull_through: criar/importar APENAS sob os prefixos de cache
      # Nada de SQS/DynamoDB aqui — isso é por pod, via IRSA (irsa.tf).
      iam_role_additional_policies = {
        ecr_read_only    = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        ecr_pull_through = aws_iam_policy.ecr_pull_through.arn
      }

      # IMDSv2 obrigatório + hop limit 1: dificulta que um pod comprometido
      # roube as credenciais do nó via SSRF no metadata endpoint.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}
