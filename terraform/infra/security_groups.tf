# Segurança em camadas: RDS e Redis aceitam conexão APENAS do Security Group
# dos nós do EKS. Nunca de 0.0.0.0/0, nem mesmo do CIDR da VPC inteira.

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Postgres 5432 apenas a partir dos nos do EKS"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres a partir dos nos do EKS"
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "Redis 6379 apenas a partir dos nos do EKS"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_nodes" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis a partir dos nos do EKS"
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# Sem regra de egress: RDS e ElastiCache não precisam iniciar conexões para
# fora. Um SG sem egress bloqueia toda saída, que é o que queremos aqui.
