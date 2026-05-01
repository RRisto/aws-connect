output "access_key_id" {
  description = "AWS access key ID for the bot builder user"
  value       = aws_iam_access_key.bot_builder.id
}

output "secret_access_key" {
  description = "AWS secret access key for the bot builder user"
  value       = aws_iam_access_key.bot_builder.secret
  sensitive   = true
}

output "iam_username" {
  description = "IAM username created"
  value       = aws_iam_user.bot_builder.name
}