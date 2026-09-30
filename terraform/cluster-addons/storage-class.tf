# StorageClass padrão gp3, atendida pelo driver EBS CSI (addon instalado no
# stack infra). A partir do EKS 1.30 nenhum StorageClass vem marcado como
# default, e o gp2 legado usa o provisionador in-tree antigo — sem isto o PVC
# do OpenBao ficaria Pending para sempre.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  # Cria o volume só quando o pod é agendado, na mesma AZ do nó escolhido.
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
