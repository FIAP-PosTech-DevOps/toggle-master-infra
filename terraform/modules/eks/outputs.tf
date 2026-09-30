output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "Base de todas as trust policies de IRSA."
  value       = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  description = "RDS e Redis só aceitam conexão vinda deste SG."
  value       = module.eks.node_security_group_id
}
