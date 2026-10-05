output "argocd_ui" {
  description = "Como abrir a interface do ArgoCD."
  value       = "kubectl port-forward -n argocd svc/argocd-server 8080:80  ->  http://localhost:8080 (usuário admin)"
}

output "argocd_admin_password" {
  description = "Comando para ler a senha inicial do admin (troque depois do primeiro login)."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "openbao_next_step" {
  description = "O OpenBao sobe selado e sem inicializar. Rode o bootstrap uma vez por ambiente."
  value       = "../../scripts/openbao-bootstrap.sh ${var.environment}"
}

output "next_step_get_nlb_hostname" {
  description = "URL pública do Ingress."
  value       = "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
