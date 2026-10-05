output "ecr_registry" {
  description = "Host do registry. Vira a variável ECR_REGISTRY nos workflows e o prefixo das imagens no repo GitOps."
  value       = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_region" {
  value = var.aws_region
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "github_actions_role_arns" {
  description = "Cadastre como variáveis nos repositórios do GitHub (ver README)."
  value = {
    ecr_push        = aws_iam_role.gha_ecr_push.arn
    terraform_plan  = aws_iam_role.gha_terraform_plan.arn
    terraform_apply = aws_iam_role.gha_terraform_apply.arn
  }
}
