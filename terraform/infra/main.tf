# -----------------------------------------------------------------------------
# Um ambiente completo do ToggleMaster (develop, staging ou production)
# -----------------------------------------------------------------------------
# Este root só compõe módulos. Cada ambiente é o MESMO código com outro
# tfvars e outro state:
#
#   ../tf.sh infra develop    plan   -> envs/develop.tfvars    (us-east-2)
#   ../tf.sh infra staging    plan   -> envs/staging.tfvars    (us-west-2)
#   ../tf.sh infra production plan   -> envs/production.tfvars (us-east-1)
# -----------------------------------------------------------------------------

module "network" {
  source = "../modules/network"

  name                 = local.name_prefix
  cluster_name         = local.cluster_name
  cidr                 = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
}

module "eks" {
  source = "../modules/eks"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = module.network.vpc_id
  subnet_ids      = module.network.private_subnet_ids
  kms_key_arn     = aws_kms_key.main.arn

  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_admin_principal_arns = local.cluster_admin_principal_arns

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_min_size       = var.node_min_size
  node_desired_size   = var.node_desired_size
  node_max_size       = var.node_max_size

  node_additional_policy_arns = {
    ecr_pull_through = aws_iam_policy.ecr_pull_through.arn
  }
}

module "data" {
  source = "../modules/data"

  name_prefix              = local.name_prefix
  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.private_subnet_ids
  client_security_group_id = module.eks.node_security_group_id
  kms_key_arn              = aws_kms_key.main.arn
  deletion_protection      = var.deletion_protection

  databases                = var.databases
  db_engine_version        = var.db_engine_version
  db_instance_class        = var.db_instance_class
  db_allocated_storage     = var.db_allocated_storage
  db_multi_az              = var.db_multi_az
  db_backup_retention_days = var.db_backup_retention_days

  redis_node_type      = var.redis_node_type
  redis_engine_version = var.redis_engine_version

  dynamodb_table_name             = var.dynamodb_table_name
  dynamodb_point_in_time_recovery = var.dynamodb_point_in_time_recovery
}

module "messaging" {
  source = "../modules/messaging"

  name_prefix       = local.name_prefix
  max_receive_count = var.sqs_max_receive_count
}

module "workload_identity" {
  source = "../modules/workload-identity"

  name_prefix        = local.name_prefix
  oidc_provider_arn  = module.eks.oidc_provider_arn
  sqs_queue_arn      = module.messaging.queue_arn
  dynamodb_table_arn = module.data.dynamodb_table_arn
}
