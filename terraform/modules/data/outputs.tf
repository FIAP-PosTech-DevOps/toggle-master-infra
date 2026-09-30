output "rds_endpoints" {
  description = "host:port de cada instância."
  value       = { for k, v in aws_db_instance.this : k => v.endpoint }
}

output "rds_addresses" {
  description = "Só o host de cada instância."
  value       = { for k, v in aws_db_instance.this : k => v.address }
}

output "rds_db_names" {
  value = { for k, v in aws_db_instance.this : k => v.db_name }
}

output "rds_master_user_secret_arns" {
  description = "ARN do secret no Secrets Manager com a senha gerada pelo RDS."
  value       = { for k, v in aws_db_instance.this : k => v.master_user_secret[0].secret_arn }
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.analytics.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.analytics.arn
}
