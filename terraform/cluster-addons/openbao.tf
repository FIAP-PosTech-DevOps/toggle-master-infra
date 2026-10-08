# -----------------------------------------------------------------------------
# OpenBao — cofre de segredos da aplicação
# -----------------------------------------------------------------------------
# Resolve o problema "credenciais do banco em arquivo de texto": DATABASE_URL,
# MASTER_KEY e SERVICE_API_KEY ficam no OpenBao, e o External Secrets
# Operator os entrega aos pods como Secret do Kubernetes. Nada sensível
# passa pelo Git.
#
# OpenBao é o fork open source (Linux Foundation) do HashiCorp Vault, com a
# mesma API — por isso o provider "vault" do External Secrets funciona com ele.
#
# Modo standalone (1 réplica) com storage pebbledb num volume EBS, e
# auto-unseal pela CMK do ambiente (IRSA, ver módulo workload-identity).
# HA com 3 réplicas Raft seria o próximo passo numa produção real.
#
# A partir do OpenBao 2.7 o seal "awskms" deixou de ser embutido no binário:
# ele virou um plugin do tipo "kms", baixado como imagem OCI na subida do
# servidor (plugin_auto_download). Sem o bloco `plugin "kms" "awskms"` o pod
# entra em CrashLoopBackOff com "unknown wrapper: awskms". O plugin herda o
# ambiente do servidor, então usa as mesmas credenciais IRSA.
# -----------------------------------------------------------------------------
resource "helm_release" "openbao" {
  name             = "openbao"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  namespace        = "openbao"
  create_namespace = true
  version          = var.openbao_chart_version

  values = [yamlencode({
    # O injector (sidecar) não é usado: quem entrega segredo aos pods é o
    # External Secrets Operator.
    injector = { enabled = false }

    ui = { enabled = true }

    server = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = local.irsa_role_arns.openbao
        }
      }

      dataStorage = {
        enabled      = true
        size         = var.openbao_storage_size
        storageClass = kubernetes_storage_class_v1.gp3.metadata[0].name
      }

      # Diretório dos plugins baixados na subida (o plugin de unseal).
      # emptyDir: é baixado de novo a cada restart, sem ocupar o PVC.
      volumes = [{
        name     = "plugins"
        emptyDir = {}
      }]
      volumeMounts = [{
        name      = "plugins"
        mountPath = "/openbao/plugins"
      }]

      # Sem isto o PVC (e o volume EBS) sobrevive ao destroy e fica
      # cobrando storage depois que o ambiente foi embora.
      persistentVolumeClaimRetentionPolicy = {
        whenDeleted = "Delete"
        whenScaled  = "Retain"
      }

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "256Mi" }
      }

      standalone = {
        enabled = true
        config  = <<-EOT
          ui = true

          listener "tcp" {
            tls_disable     = 1
            address         = "[::]:8200"
            cluster_address = "[::]:8201"
          }

          storage "pebbledb" {
            path = "/openbao/data/pebbledb"
          }

          # Plugin de auto-unseal (OpenBao 2.7+), fixado por digest.
          plugin_directory     = "/openbao/plugins"
          plugin_auto_download = true

          plugin "kms" "awskms" {
            image = "${var.openbao_kms_plugin_image}"
          }

          # Auto-unseal: a chave mestra do OpenBao é cifrada por esta CMK.
          # Um restart do pod não deixa o cofre selado.
          seal "awskms" {
            region     = "${var.aws_region}"
            kms_key_id = "${local.openbao_unseal_kms_alias}"
          }
        EOT
      }
    }
  })]

  # O pod sobe "não inicializado" e o readiness só passa depois do
  # `bao operator init` (scripts/openbao-bootstrap.sh). Esperar aqui
  # travaria o apply até o timeout.
  wait = false

  depends_on = [helm_release.aws_load_balancer_controller]
}
