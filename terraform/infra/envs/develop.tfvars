# -----------------------------------------------------------------------------
# Ambiente: develop  —  recebe deploy de cada merge na branch develop
# -----------------------------------------------------------------------------
environment = "develop"
aws_region  = "us-east-2" # Ohio

azs                  = ["us-east-2a", "us-east-2b"]
vpc_cidr             = "10.10.0.0/16"
public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24"]
private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]

# OBRIGATÓRIO: o seu usuário/role IAM, para ter kubectl no cluster.
#   aws sts get-caller-identity --query Arn --output text
# cluster_admin_principal_arns = ["arn:aws:iam::123456789012:user/seu-usuario"]

# RECOMENDADO: restrinja o endpoint do cluster ao seu IP (curl ifconfig.me).
# Atenção: o GitHub Actions também precisa alcançar o endpoint para o
# cluster-addons; restringir aqui exige runner self-hosted ou a lista de IPs
# do GitHub.
# cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]

# Ambiente de desenvolvimento: o mínimo que roda a demo.
node_desired_size   = 2
deletion_protection = false
