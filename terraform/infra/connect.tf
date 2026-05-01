# ---------------------------------------------------------------------------
# Connect instance (chat only — voice disabled)
# First-time provisioning takes ~15 minutes; do not cancel mid-apply.
# ---------------------------------------------------------------------------
resource "aws_connect_instance" "main" {
  identity_management_type = "CONNECT_MANAGED"
  inbound_calls_enabled    = false
  outbound_calls_enabled   = false
  instance_alias           = var.connect_instance_alias
}

# ---------------------------------------------------------------------------
# Associate Lex V2 bot — aws_connect_bot_association only supports Lex V1.
# Uses Python script calling 'aws connect associate-bot' instead.
# ---------------------------------------------------------------------------
resource "null_resource" "associate_lex" {
  depends_on = [aws_connect_instance.main, null_resource.bot_alias_cleanup]

  triggers = { alias_arn = local.bot_alias_arn }

  provisioner "local-exec" {
    command = "python3 ${path.module}/../../scripts/associate_lex_bot.py ${aws_connect_instance.main.id} ${local.bot_alias_arn} ${var.aws_region}"
  }
}

# ---------------------------------------------------------------------------
# Contact flow — created via Python/boto3 so InvalidContactFlowException
# exposes the 'problems' array with specific error messages (Terraform drops it).
# Script is idempotent: returns existing flow ID if already created.
# ---------------------------------------------------------------------------
data "external" "contact_flow" {
  depends_on = [null_resource.associate_lex]

  program = ["python3", "${path.module}/../../scripts/create_contact_flow.py"]

  query = {
    instance_id = aws_connect_instance.main.id
    alias_arn   = local.bot_alias_arn
    region      = var.aws_region
  }
}