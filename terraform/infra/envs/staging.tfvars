# -----------------------------------------------------------------------------
# Ambiente: staging  —  recebe as releases antes de production
# -----------------------------------------------------------------------------
# Mesma região de production: a validação da release roda nas mesmas
# condições (latência, serviços disponíveis, cotas). A VPC é outra (10.20/16)
# e todos os nomes levam o ambiente, então os dois não se misturam.
environment = "staging"
aws_region  = "us-east-1" # N. Virginia, junto de production e do ECR

azs                  = ["us-east-1a", "us-east-1b"]
vpc_cidr             = "10.20.0.0/16"
public_subnet_cidrs  = ["10.20.0.0/24", "10.20.1.0/24"]
private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]

# OBRIGATÓRIO: quem administra o cluster (kubectl), além das roles da CI.
# Usuário ou role IAM, nunca o root. Fica versionado para a pipeline usar.
cluster_admin_principal_arns = ["arn:aws:iam::413816840261:user/admin-cli"]

# Espelho de production em tamanho, para a validação da release valer. A
# redundância (NAT por AZ, RDS Multi-AZ, Redis com réplica) fica só em
# production: em staging ela dobraria o custo sem mudar o teste da aplicação.
node_desired_size   = 2
deletion_protection = false

# DynamoDB tem nome por região, e staging divide a região com production
# (que usa ToggleMasterAnalytics, nome exigido pelo desafio). Precisa casar
# com AWS_DYNAMODB_TABLE no overlay de staging do repositório GitOps.
dynamodb_table_name = "ToggleMasterAnalytics-staging"
