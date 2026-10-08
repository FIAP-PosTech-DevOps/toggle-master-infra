# -----------------------------------------------------------------------------
# Ambiente: staging  —  recebe as releases antes de production
# -----------------------------------------------------------------------------
environment = "staging"
aws_region  = "us-west-2" # Oregon

azs                  = ["us-west-2a", "us-west-2b"]
vpc_cidr             = "10.20.0.0/16"
public_subnet_cidrs  = ["10.20.0.0/24", "10.20.1.0/24"]
private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]

# OBRIGATÓRIO: quem administra o cluster (kubectl), além das roles da CI.
# Usuário ou role IAM, nunca o root. Fica versionado para a pipeline usar.
cluster_admin_principal_arns = ["arn:aws:iam::413816840261:user/admin-cli"]

# Espelho de production em tamanho, para a validação da release valer.
node_desired_size   = 2
deletion_protection = false
