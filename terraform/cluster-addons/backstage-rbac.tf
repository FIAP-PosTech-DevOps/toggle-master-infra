# -----------------------------------------------------------------------------
# Laboratório Backstage: o mínimo, além da leitura, para o plugin do ArgoCD
# -----------------------------------------------------------------------------
# A Access Entry da role do Backstage (stack infra) já dá leitura do cluster
# (AmazonEKSViewPolicy) e coloca a role no grupo "backstage-viewers". A API
# do ArgoCD não sai do cluster (Service ClusterIP), então a EC2 do Backstage
# abre um port-forward até ela, como fazemos na nossa máquina. Para isso o
# grupo precisa de duas permissões a mais, só no namespace argocd:
#
#   - pods/portforward: abrir o túnel até o argocd-server;
#   - ler UM Secret, argocd-initial-admin-secret: a senha de leitura que o
#     plugin usa para consultar o status das Applications.
#
# Sem a role do Backstage no cluster, o grupo fica vazio e isto não dá acesso
# a ninguém.
# -----------------------------------------------------------------------------

resource "kubernetes_role_v1" "backstage_argocd" {
  metadata {
    name      = "backstage-argocd-access"
    namespace = "argocd"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["argocd-initial-admin-secret"]
    verbs          = ["get"]
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_role_binding_v1" "backstage_argocd" {
  metadata {
    name      = "backstage-argocd-access"
    namespace = "argocd"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.backstage_argocd.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "backstage-viewers"
    api_group = "rbac.authorization.k8s.io"
  }
}
