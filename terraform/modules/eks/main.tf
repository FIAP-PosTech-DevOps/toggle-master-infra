# Cluster EKS de um ambiente + managed node group + driver de volumes EBS.
#
# Usa o módulo oficial terraform-aws-modules/eks: a configuração do OIDC
# (base do IRSA), das roles e dos security groups do cluster tem muitos
# detalhes fáceis de errar à mão.

locals {
  # Acesso de administrador ao cluster via Access Entries (API do EKS), sem
  # editar o ConfigMap aws-auth. Um mapa por ARN: somar ou tirar um ARN não
  # recria os outros.
  admin_access_entries = {
    for arn in var.cluster_admin_principal_arns : arn => {
      principal_arn = arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id = var.vpc_id
  # Nós só nas sub-redes privadas: nenhum nó recebe IP público.
  subnet_ids = var.subnet_ids

  # Endpoint privado sempre ligado. O público fica ligado para rodar kubectl
  # da sua máquina e para o GitHub Actions — restrinja por CIDR no tfvars.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # Secrets do etcd criptografados com a CMK do ambiente (envelope encryption).
  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = var.kms_key_arn
  }

  # O nome padrão da role (<cluster>-cluster-) estoura o limite de 38
  # caracteres do name_prefix do IAM em "togglemaster-production-cluster".
  iam_role_name = substr("${var.cluster_name}-role", 0, 37)

  # Quem tem acesso ao cluster é declarado aqui, e não "quem rodou o apply".
  # Com a CI e as pessoas aplicando o mesmo state, o "criador" mudaria a cada
  # execução e o módulo recriaria o access entry toda vez.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.admin_access_entries

  # Cria o provedor OIDC do cluster no IAM — é o que torna o IRSA possível.
  enable_irsa = true

  cluster_addons = {
    # Driver de volumes EBS: sem ele nenhum PersistentVolumeClaim é atendido.
    # O OpenBao guarda seus dados num PVC, por isso ele passou a ser
    # obrigatório nesta fase.
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      iam_role_name = substr("${var.cluster_name}-node", 0, 37)

      # Permissões do nó, todas restritas a puxar imagem. Nada de
      # SQS/DynamoDB/KMS aqui — isso é por pod, via IRSA.
      iam_role_additional_policies = merge(
        {
          ecr_read_only = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        },
        var.node_additional_policy_arns,
      )

      # IMDSv2 obrigatório + hop limit 1: um pod comprometido não consegue
      # roubar as credenciais do nó via SSRF no metadata endpoint.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}

# IRSA do driver EBS: a permissão de criar/anexar volumes é do pod do driver,
# não do nó.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
