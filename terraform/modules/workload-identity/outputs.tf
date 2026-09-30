output "role_arns" {
  value = {
    alb_controller = module.irsa_alb_controller.iam_role_arn
    evaluation     = module.irsa_evaluation.iam_role_arn
    analytics      = module.irsa_analytics.iam_role_arn
    keda           = module.irsa_keda.iam_role_arn
    openbao        = module.irsa_openbao.iam_role_arn
  }
}

output "openbao_unseal_kms_alias" {
  value = aws_kms_alias.openbao_unseal.name
}
