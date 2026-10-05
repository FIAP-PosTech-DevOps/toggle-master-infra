# --- Cluster -----------------------------------------------------------------

output "environment" {
  value = var.environment
}

output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  description = "Use em: aws eks update-kubeconfig --region <aws_region> --name <isto>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "ecr_registry" {
  description = "Registry compartilhado (stack global) de onde este cluster puxa as imagens."
  value       = local.ecr_registry
}

# --- Dados (valores não sensíveis que vão para o repo GitOps / OpenBao) ------

output "rds_endpoints" {
  value = module.data.rds_endpoints
}

output "rds_addresses" {
  value = module.data.rds_addresses
}

output "rds_db_names" {
  value = module.data.rds_db_names
}

output "rds_master_user_secret_arns" {
  description = "Secret com a senha gerada pelo RDS. Lido pelo bootstrap do OpenBao."
  value       = module.data.rds_master_user_secret_arns
}

output "redis_endpoint" {
  description = "REDIS_URL fica redis://<isto>:6379"
  value       = module.data.redis_endpoint
}

output "dynamodb_table_name" {
  value = module.data.dynamodb_table_name
}

output "sqs_queue_url" {
  value = module.messaging.queue_url
}

output "sqs_dlq_url" {
  value = module.messaging.dlq_url
}

# --- IRSA --------------------------------------------------------------------

output "irsa_role_arns" {
  description = "O cluster-addons deriva estes ARNs pela convenção de nomes; o repo GitOps usa evaluation/analytics nas ServiceAccounts."
  value       = module.workload_identity.role_arns
}

output "openbao_unseal_kms_alias" {
  value = module.workload_identity.openbao_unseal_kms_alias
}
