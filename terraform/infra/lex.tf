# ---------------------------------------------------------------------------
# IAM role for Lex V2 (required; Polly policy omitted — chat only, no TTS)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lex" {
  name = "connect-bot-lex-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lexv2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ---------------------------------------------------------------------------
# Bot
# ---------------------------------------------------------------------------
resource "aws_lexv2models_bot" "main" {
  name                        = "connect-bot"
  role_arn                    = aws_iam_role.lex.arn
  idle_session_ttl_in_seconds = 300

  data_privacy {
    child_directed = false
  }
}

# ---------------------------------------------------------------------------
# Single en_US locale only.
# ru_RU and et_ET locales only support AMAZON.QInConnectIntent and
# AMAZON.FallbackIntent — they have no NLU training data and fail to build.
# Language detection is handled in Lambda by inspecting the message text.
# ---------------------------------------------------------------------------
resource "aws_lexv2models_bot_locale" "en_us" {
  bot_id                           = aws_lexv2models_bot.main.id
  bot_version                      = "DRAFT"
  locale_id                        = "en_US"
  n_lu_intent_confidence_threshold = 0.40
}

# ---------------------------------------------------------------------------
# Greet intent (FallbackIntent is built-in, no resource needed)
# active + enabled both required for fulfillment_code_hook
# ---------------------------------------------------------------------------
resource "aws_lexv2models_intent" "greet_en" {
  bot_id      = aws_lexv2models_bot.main.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.en_us.locale_id
  name        = "Greet"

  sample_utterance { utterance = "Hello" }
  sample_utterance { utterance = "Hi" }
  sample_utterance { utterance = "Hey" }
  sample_utterance { utterance = "Good morning" }
  sample_utterance { utterance = "Good day" }

  fulfillment_code_hook {
    enabled = true
    active  = true
  }
}

# ---------------------------------------------------------------------------
# Build locale and poll until Built
# ---------------------------------------------------------------------------
resource "null_resource" "build_locales" {
  triggers = { intent_id = aws_lexv2models_intent.greet_en.id }

  provisioner "local-exec" {
    command = "python3 ${path.module}/../../scripts/build_bot_locale.py ${aws_lexv2models_bot.main.id} en_US ${var.aws_region}"
  }
}

# ---------------------------------------------------------------------------
# Bot version (snapshot of DRAFT after locale is built)
# ---------------------------------------------------------------------------
resource "aws_lexv2models_bot_version" "v1" {
  depends_on = [null_resource.build_locales]

  bot_id = aws_lexv2models_bot.main.id

  locale_specification = {
    en_US = { source_bot_version = "DRAFT" }
  }
}

# ---------------------------------------------------------------------------
# Bot alias — aws_lexv2models_bot_alias does not exist in the Terraform
# provider (as of hashicorp/aws 5.x). Created via Python script instead.
# data "external" is deferred to apply time due to depends_on, so the alias
# ARN is available to the contact flow within the same terraform apply.
# ---------------------------------------------------------------------------
data "external" "bot_alias" {
  depends_on = [aws_lexv2models_bot_version.v1, aws_lambda_function.bot]

  program = ["python3", "${path.module}/../../scripts/create_bot_alias.py"]

  query = {
    bot_id      = aws_lexv2models_bot.main.id
    bot_version = aws_lexv2models_bot_version.v1.bot_version
    lambda_arn  = aws_lambda_function.bot.arn
    region      = var.aws_region
  }
}

# ---------------------------------------------------------------------------
# Stores alias ID in triggers so the destroy provisioner can delete it.
# This runs after the alias is created and before the bot version is deleted.
# ---------------------------------------------------------------------------
resource "null_resource" "bot_alias_cleanup" {
  depends_on = [data.external.bot_alias]

  triggers = {
    bot_id = aws_lexv2models_bot.main.id
    region = var.aws_region
  }

  lifecycle {
    ignore_changes = [triggers]
  }

  provisioner "local-exec" {
    when    = destroy
    command = "python3 ${path.module}/../../scripts/delete_bot_alias.py ${self.triggers.bot_id} live ${self.triggers.region}"
  }
}

locals {
  bot_alias_arn = data.external.bot_alias.result["alias_arn"]
}