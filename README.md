# AWS Connect Chatbot

Chat-only customer-facing bot built on Amazon Connect + Lex V2 + Lambda. Supports Estonian, English, and Russian. No voice — text/chat only.

```
Amazon Connect (chat)
    └── Amazon Lex V2 (intent detection)
            └── AWS Lambda (fulfillment)
                    └── Amazon Bedrock Nova Lite (LLM responses)
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with credentials
- Python 3.11+ with `boto3` (`pip install boto3`)

---

## Step 1 — Configure AWS credentials

```bash
aws configure
# or set environment variables:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=eu-central-1
```

If you want a least-privilege IAM user instead (optional):

```bash
cd terraform/bootstrap
terraform init && terraform apply
terraform output secret_access_key
# Then configure the CLI with those credentials
```

---

## Step 2 — Deploy core infrastructure

Edit `terraform/infra/terraform.tfvars`:

```hcl
connect_instance_alias = "your-unique-name"   # globally unique, lowercase, hyphens ok
```

Deploy:

```bash
cd terraform/infra
terraform init
terraform apply
```

**What this deploys, in order:**

1. Lambda function (`connect-bot-handler`) calling Amazon Bedrock Nova Lite
2. Lex V2 bot — single `en_US` locale (language detected in Lambda, not Lex)
3. `Greet` intent with sample utterances + built-in `FallbackIntent`
4. Locale build (polled until `Built` — ~1 min)
5. Bot version snapshot
6. Bot alias `live` wired to Lambda (via `scripts/create_bot_alias.py`)
7. Amazon Connect instance — **takes ~15 minutes, do not cancel**
8. Lex V2 bot associated with Connect (via `scripts/associate_lex_bot.py`)
9. Contact flow `connect-bot-chat-flow` (via `scripts/create_contact_flow.py`)

Full apply time: **~20–25 minutes**.

---

## Step 3 — Configure FallbackIntent (required after first deploy)

Terraform cannot manage `AMAZON.FallbackIntent` via the provider. Run this once after every fresh deploy:

```bash
# 1. Enable the Lambda fulfillment hook
python3 scripts/enable_fallback_intent.py <lex-bot-id> eu-central-1

# 2. Rebuild the locale
python3 scripts/build_bot_locale.py <lex-bot-id> en_US eu-central-1

# 3. Create a new bot version
aws lexv2-models create-bot-version \
  --bot-id <lex-bot-id> \
  --bot-version-locale-specification '{"en_US": {"sourceBotVersion": "DRAFT"}}' \
  --region eu-central-1 --query "botVersion" --output text

# 4. Update the alias to the new version (use alias ID from terraform output)
aws lexv2-models update-bot-alias \
  --bot-id <lex-bot-id> \
  --bot-alias-id <alias-id> \
  --bot-alias-name live \
  --bot-version <new-version> \
  --bot-alias-locale-settings '{"en_US": {"enabled": true, "codeHookSpecification": {"lambdaCodeHook": {"lambdaARN": "arn:aws:lambda:eu-central-1:<account>:function:connect-bot-handler", "codeHookInterfaceVersion": "1.0"}}}}' \
  --region eu-central-1
```

Get the bot ID and alias ID from Terraform outputs:

```bash
terraform output lex_bot_id
terraform output lex_bot_alias_arn   # alias ID is the last segment after the final /
```

---

## Step 4 — Create a Connect admin user

The Connect instance has its own user directory (separate from AWS IAM). Create an admin user to access the chat console:

```bash
# Get IDs
INSTANCE_ID=$(terraform output -raw connect_instance_id)
ROUTING_ID=$(aws connect list-routing-profiles --instance-id $INSTANCE_ID --region eu-central-1 \
  --query "RoutingProfileSummaryList[0].Id" --output text)
SECURITY_ID=$(aws connect list-security-profiles --instance-id $INSTANCE_ID --region eu-central-1 \
  --query "SecurityProfileSummaryList[?Name=='Admin'].Id | [0]" --output text)

# Create user
aws connect create-user \
  --username admin \
  --password "Admin123!@#" \
  --identity-info FirstName=Admin,LastName=User \
  --phone-config PhoneType=SOFT_PHONE \
  --security-profile-ids $SECURITY_ID \
  --routing-profile-id $ROUTING_ID \
  --instance-id $INSTANCE_ID \
  --region eu-central-1
```

Log in at `https://<instance-alias>.my.connect.aws/login`.

---

## Step 5 — Test the bot

1. Open `https://<instance-alias>.my.connect.aws/login` and log in
2. Go to **Test chat** (phone icon in the left sidebar)
3. Select flow: `connect-bot-chat-flow`
4. Click **Test** and type a message

| Language | Example input | Expected behaviour |
| -------- | ------------- | ------------------ |
| English  | `Hello` / `I need help` | Replies in English |
| Russian  | `Привет` / `Мне нужна помощь` | Replies in Russian |
| Estonian | `Tere` / `Mul on küsimus` | Replies in Estonian |

### Test Lambda directly

```bash
aws lambda invoke \
  --function-name connect-bot-handler \
  --payload '{"sessionState":{"intent":{"name":"FallbackIntent","state":"InProgress"}},"inputTranscript":"I need help","invocationSource":"FulfillmentCodeHook"}' \
  --cli-binary-format raw-in-base64-out \
  response.json && cat response.json
```

---

## Updating the bot

**Change the prompt or response logic** — edit `lambda/handler.py`, then:
```bash
cd terraform/infra && terraform apply
```
Terraform detects source changes via `source_code_hash` and redeploys Lambda automatically. No Connect instance reprovisioning.

**Add a new intent** — add an `aws_lexv2models_intent` resource in `terraform/infra/lex.tf`, re-apply, then run the Step 3 scripts to rebuild and version the bot.

---

## Teardown

```bash
cd terraform/infra && terraform destroy
cd terraform/bootstrap && terraform destroy   # if you ran the bootstrap
```

The `live` bot alias is deleted automatically by a destroy provisioner. If destroy fails partway through, delete the alias manually:

```bash
aws lexv2-models list-bot-aliases --bot-id <bot-id> --region eu-central-1
aws lexv2-models delete-bot-alias --bot-id <bot-id> --bot-alias-id <alias-id> --region eu-central-1
# Then re-run terraform destroy
```

---

## Architecture notes

- **Single Lex locale (`en_US`)** — `ru_RU` and `et_ET` cannot be built (no supported NLU training data). Language is detected in Lambda by inspecting the message text: Cyrillic → Russian, Estonian characters (äöüõ) → Estonian, otherwise English.
- **LLM model** — Amazon Bedrock Nova Lite (`eu.amazon.nova-lite-v1:0` inference profile for EU regions). No Anthropic account required.
- **`aws_lexv2models_bot_alias`** — does not exist in the Terraform AWS provider (5.x). Managed via `scripts/create_bot_alias.py`.
- **`aws_connect_bot_association`** — only supports Lex V1. Lex V2 association handled via `scripts/associate_lex_bot.py`.
- **`AMAZON.FallbackIntent`** — cannot be fully managed via Terraform or the AWS CLI (name conflicts). Configured via `scripts/enable_fallback_intent.py` using boto3 after each deploy.
- **Contact flow** — created via `scripts/create_contact_flow.py` (boto3) rather than `aws_connect_contact_flow` Terraform resource, because the resource's error messages omit the `problems` array needed for debugging.

## Future phases

- RAG via Amazon Bedrock + Knowledge Base
- Human escalation (transfer to agent queue)
- Voice support (add Polly IAM policy to the Lex role)
