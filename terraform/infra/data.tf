# Descobre o account ID da conta em que você está autenticado — evita
# hardcodar o número em ARNs e no host do ECR.
data "aws_caller_identity" "current" {}
