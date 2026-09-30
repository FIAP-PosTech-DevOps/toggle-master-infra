# -----------------------------------------------------------------------------
# Ambiente: production  —  recebe deploy da main, dentro da janela do ArgoCD
# -----------------------------------------------------------------------------
environment = "production"
aws_region  = "us-east-1" # N. Virginia (mesma região do ECR compartilhado)

azs                  = ["us-east-1a", "us-east-1b"]
vpc_cidr             = "10.30.0.0/16"
public_subnet_cidrs  = ["10.30.0.0/24", "10.30.1.0/24"]
private_subnet_cidrs = ["10.30.10.0/24", "10.30.11.0/24"]

# OBRIGATÓRIO: o seu usuário/role IAM, para ter kubectl no cluster.
# cluster_admin_principal_arns = ["arn:aws:iam::123456789012:user/seu-usuario"]

node_desired_size = 2

# Em uma produção real ligaríamos as proteções abaixo. Ficam desligadas
# porque o laboratório é destruído ao fim de cada sessão (custo).
# deletion_protection             = true
# db_multi_az                     = true
# db_backup_retention_days        = 7
# dynamodb_point_in_time_recovery = true
# single_nat_gateway              = false
