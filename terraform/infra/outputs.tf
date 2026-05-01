output "connect_instance_id" {
  description = "Amazon Connect instance ID"
  value       = aws_connect_instance.main.id
}

output "connect_instance_arn" {
  description = "Amazon Connect instance ARN"
  value       = aws_connect_instance.main.arn
}

output "lex_bot_id" {
  description = "Lex V2 bot ID"
  value       = aws_lexv2models_bot.main.id
}

output "lex_bot_alias_arn" {
  description = "Lex V2 bot alias ARN"
  value       = local.bot_alias_arn
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.bot.function_name
}

output "contact_flow_id" {
  description = "Connect contact flow ID"
  value       = data.external.contact_flow.result["flow_id"]
}

output "docs_bucket_name" {
  description = "S3 bucket where RAG documents are uploaded"
  value       = aws_s3_bucket.docs.bucket
}

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID — pass to scripts/sync_kb.py after uploading docs"
  value       = aws_bedrockagent_knowledge_base.main.id
}

output "aurora_cluster_arn" {
  description = "Aurora cluster ARN backing the Bedrock KB vector store"
  value       = aws_rds_cluster.rag.arn
}

output "aurora_secret_arn" {
  description = "Secrets Manager ARN holding Aurora master credentials"
  value       = aws_secretsmanager_secret.aurora.arn
}