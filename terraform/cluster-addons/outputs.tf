output "app_namespace" {
  value = kubernetes_namespace.app.metadata[0].name
}

output "service_account_names" {
  description = "Use estes nomes em spec.template.spec.serviceAccountName nos Deployments."
  value = {
    evaluation = kubernetes_service_account.evaluation.metadata[0].name
    analytics  = kubernetes_service_account.analytics.metadata[0].name
  }
}

output "next_step_get_nlb_hostname" {
  description = "Rode este comando depois do apply para descobrir a URL pública do Ingress."
  value       = "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
