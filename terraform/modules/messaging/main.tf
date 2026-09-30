# Fila de eventos de avaliação (evaluation-service -> analytics-service) com
# dead-letter queue.

# A DLQ existe antes para a fila principal referenciar o ARN dela.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-queue-dlq"
  message_retention_seconds = 1209600 # 14 dias, o máximo
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  name = "${var.name_prefix}-queue"

  # Tempo que uma mensagem fica invisível depois de lida, para o
  # analytics-service processar e deletar antes de outro pod pegar a mesma.
  visibility_timeout_seconds = var.visibility_timeout_seconds

  sqs_managed_sse_enabled = true

  # Depois de N tentativas falhas a mensagem vai para a DLQ, em vez de travar
  # o worker em loop com um payload inválido.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Só a fila principal pode mandar mensagens para a DLQ.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}
