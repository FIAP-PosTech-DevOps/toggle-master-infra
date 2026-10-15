# -----------------------------------------------------------------------------
# Ambiente: production  —  recebe deploy da main, dentro da janela do ArgoCD
# -----------------------------------------------------------------------------
environment = "production"
aws_region  = "us-east-1" # N. Virginia (mesma região do ECR compartilhado)

azs                  = ["us-east-1a", "us-east-1b"]
vpc_cidr             = "10.30.0.0/16"
public_subnet_cidrs  = ["10.30.0.0/24", "10.30.1.0/24"]
private_subnet_cidrs = ["10.30.10.0/24", "10.30.11.0/24"]

# OBRIGATÓRIO: quem administra o cluster (kubectl), além das roles da CI.
# Usuário ou role IAM, nunca o root. Fica versionado para a pipeline usar.
cluster_admin_principal_arns = ["arn:aws:iam::413816840261:user/admin-cli"]

# --- Redundância em 2 Availability Zones ------------------------------------
# Production continua no ar se uma AZ inteira cair:
#   - rede: um NAT Gateway por AZ (sem ele, as sub-redes privadas da AZ que
#     sobrou perdem a saída para a internet junto com o NAT da AZ que caiu);
#   - EKS: no mínimo 2 nós, um em cada AZ (o node group usa as sub-redes das
#     duas); os overlays de production espalham as réplicas pelas zonas;
#   - RDS: Multi-AZ, réplica síncrona na outra AZ com failover automático;
#   - Redis: primário + réplica em AZs diferentes, com failover automático.
# DynamoDB e SQS já são multi-AZ por natureza. Custo: ~US$0,12/h a mais
# que staging (2º NAT, standby dos 3 RDS e a réplica do Redis).
single_nat_gateway       = false
node_min_size            = 2
node_desired_size        = 2
db_multi_az              = true
redis_num_cache_clusters = 2

# Numa produção real ligaríamos também as proteções abaixo. Ficam desligadas
# porque o laboratório é destruído ao fim de cada sessão.
# deletion_protection             = true
# db_backup_retention_days        = 7
# dynamodb_point_in_time_recovery = true
