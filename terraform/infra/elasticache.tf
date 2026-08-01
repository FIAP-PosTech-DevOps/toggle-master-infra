resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-redis-subnets"
  subnet_ids = module.vpc.private_subnets
}

# Usamos aws_elasticache_replication_group (e não aws_elasticache_cluster)
# porque é o único que suporta at_rest_encryption_enabled para Redis. Com
# num_cache_clusters = 1 ele cria um nó único, sem réplica — mesma pegada de
# custo do cluster simples, mas com criptografia em repouso e com caminho
# fácil para adicionar réplica depois (basta subir num_cache_clusters para 2
# e ligar automatic_failover_enabled).
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "${local.name_prefix} - cache do evaluation-service"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  # Sem réplica => sem failover automático.
  automatic_failover_enabled = false
  multi_az_enabled           = false

  at_rest_encryption_enabled = true

  # Criptografia em trânsito NÃO foi habilitada de propósito: o
  # evaluation-service conecta com REDIS_URL simples (redis://), sem TLS nem
  # AUTH token. Para ligar em produção real seria transit_encryption_enabled
  # = true + auth_token, e o código passaria a usar rediss:// com senha.
  transit_encryption_enabled = false

  snapshot_retention_limit = 0
  apply_immediately        = true
}
