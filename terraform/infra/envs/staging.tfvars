# -----------------------------------------------------------------------------
# Ambiente: staging  —  recebe as releases antes de production
# -----------------------------------------------------------------------------
environment = "staging"
aws_region  = "us-west-2" # Oregon

azs                  = ["us-west-2a", "us-west-2b"]
vpc_cidr             = "10.20.0.0/16"
public_subnet_cidrs  = ["10.20.0.0/24", "10.20.1.0/24"]
private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]

# OBRIGATÓRIO: o seu usuário/role IAM, para ter kubectl no cluster.
# cluster_admin_principal_arns = ["arn:aws:iam::123456789012:user/seu-usuario"]

# Espelho de production em tamanho, para a validação da release valer.
node_desired_size   = 2
deletion_protection = false
