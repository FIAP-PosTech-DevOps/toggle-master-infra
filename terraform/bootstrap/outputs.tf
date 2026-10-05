output "state_bucket" {
  description = "Nome do bucket de state. O tf.sh descobre este valor sozinho pelo account ID."
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_region" {
  value = var.aws_region
}
