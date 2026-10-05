# -----------------------------------------------------------------------------
# External Secrets Operator — ponte entre o OpenBao e os pods
# -----------------------------------------------------------------------------
# O repositório GitOps declara ExternalSecret ("quero a chave X do OpenBao
# como Secret Y"), e o operador cria/atualiza o Secret do Kubernetes. O Git
# guarda a referência, nunca o valor.
#
# O ClusterSecretStore (endereço do OpenBao + autenticação Kubernetes) também
# fica no repositório GitOps, porque depende dos CRDs instalados aqui.
# -----------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = var.external_secrets_chart_version

  values = [yamlencode({
    installCRDs = true
  })]

  depends_on = [helm_release.aws_load_balancer_controller]

  timeout = 600
}
