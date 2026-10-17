output "instance_id" {
  description = "EC2 do Backstage."
  value       = aws_instance.backstage.id
}

output "tunnel_command" {
  description = "Abre o Backstage em http://localhost:7007 (precisa do Session Manager plugin do AWS CLI)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.backstage.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=7007,localPortNumber=7007"
}

output "logs_command" {
  description = "Acompanha a instalação (cloud-init) e o Backstage."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.backstage.id}   # depois: sudo tail -f /var/log/backstage-bootstrap.log ; sudo docker logs -f backstage"
}
