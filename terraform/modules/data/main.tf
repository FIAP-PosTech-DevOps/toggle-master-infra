# Camada de dados de um ambiente: 3 PostgreSQL (RDS), 1 Redis (ElastiCache)
# e a tabela de analytics (DynamoDB).

# -----------------------------------------------------------------------------
# Security groups: RDS e Redis aceitam conexão APENAS do SG dos nós do EKS.
# Nunca de 0.0.0.0/0, nem do CIDR da VPC inteira.
# -----------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Postgres 5432 apenas a partir dos nos do EKS"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres a partir dos nos do EKS"
  referenced_security_group_id = var.client_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis-sg"
  description = "Redis 6379 apenas a partir dos nos do EKS"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_nodes" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis a partir dos nos do EKS"
  referenced_security_group_id = var.client_security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# Sem regra de egress: RDS e ElastiCache não iniciam conexões para fora.

# -----------------------------------------------------------------------------
# RDS PostgreSQL — uma instância por serviço (auth, flag, targeting)
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.subnet_ids
}

# manage_master_user_password = true: o próprio RDS gera a senha e guarda no
# Secrets Manager. A senha nunca passa pelo código, pelo tfvars nem pelo
# state. O bootstrap do OpenBao lê de lá para montar a DATABASE_URL.
resource "aws_db_instance" "this" {
  for_each = var.databases

  identifier     = "${var.name_prefix}-${each.key}-db"
  db_name        = each.value
  engine         = "postgres"
  engine_version = var.db_engine_version

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  username                    = "postgres"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Single-AZ por padrão para caber no orçamento (Multi-AZ dobra o custo de
  # cada uma das 3 instâncias). Liga por ambiente via tfvars.
  multi_az = var.db_multi_az

  # Logs do Postgres no CloudWatch (erros, conexões recusadas, queries lentas).
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Permite autenticar com token IAM no lugar de senha (não usado pelos
  # serviços hoje, mas deixa o caminho aberto sem custo).
  iam_database_authentication_enabled = true

  backup_retention_period      = var.db_backup_retention_days
  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true
  copy_tags_to_snapshot        = true

  # Ambientes descartáveis: destroy sem snapshot final e sem proteção.
  # Em production real: deletion_protection = true e skip_final_snapshot = false.
  skip_final_snapshot = !var.deletion_protection
  deletion_protection = var.deletion_protection

  final_snapshot_identifier = var.deletion_protection ? "${var.name_prefix}-${each.key}-final" : null

  apply_immediately = true
}

# -----------------------------------------------------------------------------
# ElastiCache Redis — cache do evaluation-service
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-redis-subnets"
  subnet_ids = var.subnet_ids
}

# replication_group (e não aws_elasticache_cluster) porque é o único que
# suporta criptografia em repouso. Com num_cache_clusters = 1 é um nó único,
# mesma pegada de custo, com caminho fácil para réplica depois.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "${var.name_prefix} - cache do evaluation-service"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = false
  multi_az_enabled           = false

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn

  # Criptografia em trânsito desligada de propósito: o evaluation-service usa
  # redis:// sem TLS nem AUTH. Ligar exige mudar o código para rediss:// com
  # senha — risco assumido e registrado desde a Fase 2.
  transit_encryption_enabled = false

  snapshot_retention_limit = 0
  apply_immediately        = true
}

# -----------------------------------------------------------------------------
# DynamoDB — eventos de analytics
# -----------------------------------------------------------------------------

# Chave de partição event_id (String), exatamente o que o analytics-service
# espera. PAY_PER_REQUEST: paga por requisição, sem dimensionar RCU/WCU.
resource "aws_dynamodb_table" "analytics" {
  #checkov:skip=CKV_AWS_119:CMK evitada de proposito (custo por requisicao e IAM extra no analytics)
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  # Criptografia em repouso com a chave gerenciada pela AWS (padrão, sem
  # custo). Uma CMK aqui cobraria por requisição num serviço de muita escrita
  # e exigiria kms:* na role do analytics-service.

  point_in_time_recovery {
    enabled = var.dynamodb_point_in_time_recovery
  }

  deletion_protection_enabled = var.deletion_protection
}
