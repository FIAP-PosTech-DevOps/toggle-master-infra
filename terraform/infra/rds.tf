resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = module.vpc.private_subnets
}

# 3 instâncias PostgreSQL independentes (auth, flag, targeting), conforme o
# checklist do desafio.
#
# manage_master_user_password = true: o próprio RDS gera a senha e guarda no
# Secrets Manager. A senha nunca passa pelo seu código, pelo tfvars nem pelo
# state do Terraform — é a razão de não existir nenhuma variável de senha
# neste projeto. Para ler o valor, veja o output rds_master_user_secret_arns.
resource "aws_db_instance" "this" {
  for_each = var.databases

  identifier     = "${local.name_prefix}-${each.key}-db"
  db_name        = each.value
  engine         = "postgres"
  engine_version = var.db_engine_version

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.main.arn

  username                    = "postgres"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Single-AZ para caber no orçamento: Multi-AZ dobraria o custo de cada uma
  # das 3 instâncias. Documente esse trade-off no relatório de entrega.
  multi_az = false

  # Backup mínimo e nada de Performance Insights / Enhanced Monitoring
  # (ambos custam à parte e não são necessários para o desafio).
  backup_retention_period      = 1
  performance_insights_enabled = false
  monitoring_interval          = 0

  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true
}
