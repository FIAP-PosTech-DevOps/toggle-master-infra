# A DLQ precisa existir antes para podermos referenciar o ARN dela na fila
# principal — o Terraform resolve essa ordem sozinho pela referência.
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name_prefix}-queue-dlq"
  message_retention_seconds = 1209600 # 14 dias, o máximo
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  name = "${local.name_prefix}-queue"

  # Tempo que uma mensagem fica invisível depois de lida, para o
  # analytics-service processar e deletar antes de outro pod pegar a mesma.
  visibility_timeout_seconds = 60

  sqs_managed_sse_enabled = true

  # Depois de N tentativas falhas, a mensagem vai para a DLQ em vez de ficar
  # em loop infinito. Sem isso, um evento com payload inválido travaria o
  # worker para sempre.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}
