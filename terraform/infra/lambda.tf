# ---------------------------------------------------------------------------
# Package the handler into a zip on every content change
# ---------------------------------------------------------------------------
data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/handler.py"
  output_path = "${path.module}/../../lambda/handler.zip"
}

# ---------------------------------------------------------------------------
# IAM execution role (prefixed connect-bot- to match bootstrap policy scope)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lambda" {
  name = "connect-bot-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_bedrock" {
  name = "connect-bot-lambda-bedrock"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeNovaLite"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.nova-lite-v1:0",
          "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0",
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/eu.amazon.nova-lite-v1:0",
        ]
      },
      {
        Sid      = "RetrieveFromKnowledgeBase"
        Effect   = "Allow"
        Action   = ["bedrock:Retrieve"]
        Resource = [aws_bedrockagent_knowledge_base.main.arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "bot" {
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  function_name    = "connect-bot-handler"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.main.id
    }
  }
}

# Allow Lex V2 to invoke the function
resource "aws_lambda_permission" "lex" {
  statement_id  = "AllowLexV2Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bot.function_name
  principal     = "lexv2.amazonaws.com"
}