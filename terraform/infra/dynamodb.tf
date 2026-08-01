# Chave de partição event_id (String), sem chave de ordenação — exatamente o
# que o analytics-service (app.py) espera ao montar o item.
#
# PAY_PER_REQUEST: você paga por escrita/leitura, não por capacidade
# provisionada. Para um laboratório com tráfego esporádico, é a opção mais
# barata e evita ter que dimensionar RCU/WCU.
#
# Criptografia em repouso é padrão no DynamoDB (chave gerenciada pela AWS,
# sem custo), então não declaramos server_side_encryption com CMK aqui.
resource "aws_dynamodb_table" "analytics" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }
}
