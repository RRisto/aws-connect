variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "connect_instance_alias" {
  description = "Globally-unique alias for the Amazon Connect instance (lowercase letters, numbers, hyphens)"
  type        = string
}