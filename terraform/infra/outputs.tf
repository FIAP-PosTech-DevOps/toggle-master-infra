# --- Rede e cluster ----------------------------------------------------------

output "cluster_name" {
  description = "Use em: aws eks update-kubeconfig --name <isto>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

# --- Onde publicar as imagens ------------------------------------------------

output "ecr_repository_urls" {
  description = "URL de push/pull de cada repositório ECR."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "ecr_registry" {
  description = "Host do registry, para o docker login."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_pull_through_prefixes" {
  description = "Prefixos de pull-through cache. Uma imagem antes em registry.k8s.io/metrics-server/x passa a ser <registry>/k8s/metrics-server/x."
  value = {
    k8s        = aws_ecr_pull_through_cache_rule.k8s.ecr_repository_prefix
    ecr_public = aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix
  }
}

output "ecr_mirror_prefix" {
  description = "Prefixo dos repositórios espelhados manualmente (KEDA/ghcr.io e imagens base do Docker Hub), populados por k8s/mirror-images.sh."
  value       = "mirror"
}

# --- Strings de conexão (vão para os Secrets/ConfigMap do Kubernetes) -------

output "rds_endpoints" {
  description = "host:port de cada instância RDS."
  value       = { for k, v in aws_db_instance.this : k => v.endpoint }
}

output "rds_db_names" {
  value = { for k, v in aws_db_instance.this : k => v.db_name }
}

output "rds_master_user_secret_arns" {
  description = "ARN do secret no Secrets Manager com a senha que o RDS gerou. Leia com: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text"
  value       = { for k, v in aws_db_instance.this : k => v.master_user_secret[0].secret_arn }
}

output "redis_endpoint" {
  description = "Host do Redis. REDIS_URL fica redis://<isto>:6379"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.analytics.name
}

output "sqs_queue_url" {
  description = "Valor de AWS_SQS_URL no ConfigMap."
  value       = aws_sqs_queue.main.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.main.arn
}

output "sqs_dlq_url" {
  value = aws_sqs_queue.dlq.url
}

# --- IRSA --------------------------------------------------------------------

output "irsa_role_arns" {
  description = "ARNs das roles IRSA. O módulo cluster-addons deriva estes valores sozinho pela convenção de nomes — este output existe só para conferência."
  value = {
    alb_controller = module.irsa_alb_controller.iam_role_arn
    evaluation     = module.irsa_evaluation.iam_role_arn
    analytics      = module.irsa_analytics.iam_role_arn
    keda           = module.irsa_keda.iam_role_arn
  }
}
