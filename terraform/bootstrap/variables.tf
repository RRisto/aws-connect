variable "aws_region" {
  description = "AWS region used by the provider"
  type        = string
  default     = "eu-central-1"
}

variable "iam_username" {
  description = "Name of the IAM user that will build all subsequent infrastructure"
  type        = string
  default     = "connect-bot-builder"
}