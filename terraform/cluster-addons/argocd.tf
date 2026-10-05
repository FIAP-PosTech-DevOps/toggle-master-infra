# -----------------------------------------------------------------------------
# ArgoCD — o deploy das aplicações deixa de ser `kubectl apply` da máquina de
# alguém e passa a ser o ArgoCD puxando do repositório GitOps (pull model).
# -----------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = var.argocd_chart_version

  values = [yamlencode({
    configs = {
      params = {
        # A UI é acessada por port-forward (sem Ingress/TLS público). Com
        # insecure o argocd-server serve HTTP puro e o port-forward funciona
        # sem aviso de certificado.
        "server.insecure" = true
      }
      cm = {
        # Intervalo de polling do repositório GitOps.
        "timeout.reconciliation" = var.argocd_reconciliation_timeout
      }
    }

    # Sem SSO nem notificações neste projeto: menos pods disputando os 2 nós.
    dex           = { enabled = false }
    notifications = { enabled = false }

    server = {
      service = { type = "ClusterIP" }
    }
  })]

  # O webhook do ALB controller intercepta a criação de todo Service do
  # cluster; subir junto com ele gera "no endpoints available".
  depends_on = [helm_release.aws_load_balancer_controller]

  timeout = 600
}

# Application raiz ("app-of-apps"): aponta para clusters/<ambiente> no
# repositório GitOps. Tudo o que estiver lá — plataforma e os 5 serviços —
# vira Application filha e é sincronizado automaticamente. É a única
# Application criada fora do Git.
#
# Criada pelo chart argocd-apps (e não por kubernetes_manifest) porque o CRD
# Application só passa a existir depois do helm_release acima, e o
# kubernetes_manifest exige o CRD já no `plan`.
resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  namespace  = "argocd"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        finalizers = [
          "resources-finalizer.argocd.argoproj.io",
        ]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_target_revision
          path           = "clusters/${var.environment}"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
