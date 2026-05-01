# ---------------------------------------------------------------------------
# IAM user — programmatic access only (no console login)
# ---------------------------------------------------------------------------
resource "aws_iam_user" "bot_builder" {
  name = var.iam_username
  path = "/"
}

resource "aws_iam_access_key" "bot_builder" {
  user = aws_iam_user.bot_builder.name
}

# ---------------------------------------------------------------------------
# Least-privilege inline policy
# ---------------------------------------------------------------------------
resource "aws_iam_user_policy" "bot_builder" {
  name = "${var.iam_username}-policy"
  user = aws_iam_user.bot_builder.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Lex V2 — full access (bot + slot types + intents)
      {
        Sid      = "LexV2FullAccess"
        Effect   = "Allow"
        Action   = ["lex:*"]
        Resource = "*"
      },
      # Amazon Connect — instance, contact flows, queues
      {
        Sid      = "ConnectFullAccess"
        Effect   = "Allow"
        Action   = ["connect:*"]
        Resource = "*"
      },
      # Lambda — functions and event source mappings
      {
        Sid      = "LambdaFullAccess"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "*"
      },
      # IAM — scoped to roles prefixed with "connect-bot-"
      # PassRole is required by Lambda and Lex to assume execution roles
      {
        Sid    = "IAMBotRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::*:role/connect-bot-*"
      },
      # CloudWatch Logs — Lambda execution logs
      {
        Sid      = "CloudWatchLogsFullAccess"
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = "*"
      },
      # S3 — Lambda deployment package storage + RAG docs bucket
      {
        Sid      = "S3FullAccess"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      },
      # Bedrock Knowledge Base + foundation model access checks
      {
        Sid    = "BedrockFullAccess"
        Effect = "Allow"
        Action = [
          "bedrock:*",
        ]
        Resource = "*"
      },
      # RDS Aurora Serverless v2 (vector store) + Data API for schema init
      {
        Sid    = "RDSAndDataAPI"
        Effect = "Allow"
        Action = [
          "rds:*",
          "rds-data:*",
        ]
        Resource = "*"
      },
      # Secrets Manager — Aurora master credentials (Bedrock KB requires it)
      {
        Sid      = "SecretsManagerFullAccess"
        Effect   = "Allow"
        Action   = ["secretsmanager:*"]
        Resource = "*"
      },
      # EC2 — VPC, subnets, security groups, AZ lookup for Aurora
      {
        Sid      = "EC2VPC"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      # IAM service-linked roles — RDS and Bedrock create them automatically
      {
        Sid    = "IAMServiceLinkedRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:GetRole",
        ]
        Resource = "arn:aws:iam::*:role/aws-service-role/*"
      },
    ]
  })
}