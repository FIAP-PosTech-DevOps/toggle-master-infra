# O ingress-nginx é quem interpreta as regras de roteamento (/auth, /flags,
# /targeting, /evaluate). Ele pede um Service type=LoadBalancer, e as
# annotations abaixo mandam o aws-load-balancer-controller criar um NLB
# internet-facing apontando direto para os IPs dos pods (target-type: ip).
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = var.ingress_nginx_chart_version

  # Imagens via pull-through cache do ECR em vez de registry.k8s.io direto.
  # São duas: o controller e o kube-webhook-certgen do admission webhook.
  #
  # O digest é zerado de propósito: o chart fixa um sha256 do manifesto no
  # upstream, e ao trocar o registro a validação por digest tende a falhar.
  # A tag continua fixa, então a imagem permanece determinística.
  set {
    name  = "controller.image.registry"
    value = local.registry_k8s
  }

  set {
    name  = "controller.image.digest"
    value = ""
  }

  set {
    name  = "controller.admissionWebhooks.patch.image.registry"
    value = local.registry_k8s
  }

  set {
    name  = "controller.admissionWebhooks.patch.image.digest"
    value = ""
  }

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "external"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "ip"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # depends_on necessário de verdade aqui: se o ingress-nginx subir antes do
  # controller estar pronto, o Service fica com EXTERNAL-IP <pending> e
  # ninguém cria o NLB.
  depends_on = [helm_release.aws_load_balancer_controller]
}
