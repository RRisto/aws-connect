# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

AWS Connect chatbot (chat only, no voice) for Estonian, English, and Russian, built with Terraform + Lambda.

Architecture: **Amazon Connect → Lex V2 → Lambda → (Bedrock Knowledge Base + Nova Lite)**

## Repo layout

```
terraform/bootstrap/   # One-time IAM user setup (run with admin creds)
terraform/infra/       # Core infra: Lambda, Lex V2, Amazon Connect
lambda/handler.py      # Lex V2 fulfillment handler
scripts/               # Python helpers called by Terraform local-exec
```

## Deployment

**Phase 1 — Bootstrap (once, with admin AWS credentials):**
```bash
cd terraform/bootstrap
terraform init && terraform apply
```

**Phase 2 — Core infra:**
```bash
cd terraform/infra
terraform init
terraform apply -var="connect_instance_alias=<globally-unique-name>"
```

Connect instance provisioning takes ~15 minutes. The bot alias is created via `scripts/create_bot_alias.py` (called by `data "external"` in `lex.tf`) so there is no separate manual step.

## Key constraints and non-obvious decisions

- **`aws_lexv2models_bot_alias`** does not exist in the Terraform AWS provider (5.x). The alias is managed via `data "external"` + `scripts/create_bot_alias.py`.
- **`aws_connect_bot_association`** only supports Lex V1. Lex V2 association is done via `scripts/associate_lex_bot.py` using `aws connect associate-bot`.
- **Estonian locale is `et_ET`**, not `et_EE`. Russian `ru_RU` is confirmed supported.
- **`ru_RU` and `et_ET` locales cannot be built** — they have no NLU training data (only `AMAZON.FallbackIntent` and `AMAZON.QInConnectIntent` are allowed, neither provides utterances). These locales were removed entirely. The bot uses a single `en_US` Lex locale. Language is detected in Lambda (`_detect_language`) by inspecting the message text: Cyrillic → `ru_RU`, Estonian chars (äöüõ) → `et_ET`, otherwise `en_US`.
- **Contact flow action type** for Lex V2 chat is `ConnectParticipantWithLexBot` (not `GetParticipantInput`).
- **`fulfillment_code_hook`** in `aws_lexv2models_intent` requires both `enabled = true` and `active = true`.
- IAM roles created by Terraform must be prefixed `connect-bot-` to fall within the bootstrap user's scoped IAM permissions.

## RAG (Retrieval-Augmented Generation)

- Stack lives in `terraform/infra/rag.tf`: S3 docs bucket → Bedrock Knowledge Base (Cohere multilingual embeddings, 1024 dim) → Aurora Serverless v2 + pgvector.
- **Vector store choice** — Aurora pgvector with auto-pause (`min_capacity = 0`, ~$0 idle). OpenSearch Serverless was rejected because of its $345/mo minimum.
- **Lambda integration** — `lambda/handler.py` calls `bedrock-agent-runtime:Retrieve` (NOT `RetrieveAndGenerate`) before `bedrock-runtime:InvokeModel`, so the Nova Lite multilingual system prompt stays under our control. Retrieve failures degrade gracefully to no-context (try/except).
- **Aurora schema** — Bedrock KB requires the exact table layout `bedrock_integration.bedrock_kb (id uuid, embedding vector(1024), chunks text, metadata jsonb)`. Created idempotently via `scripts/init_aurora_schema.py` using the RDS Data API. Run before KB creation; ordering is enforced via `null_resource.init_aurora_schema` → `aws_bedrockagent_knowledge_base.main` `depends_on`.
- **Aurora engine version** — `16.13`. Aurora 15.4 (the version many tutorials use) is not available in `eu-central-1`. Check `aws rds describe-db-engine-versions --engine aurora-postgresql --region eu-central-1` before bumping.
- **Bedrock model access** — the AWS console "Model access" page was retired in late 2025. Serverless models auto-enable on first invocation. Step 1 of the README shows the one-shot CLI calls that trigger this for Nova Lite and Cohere Embed Multilingual v3.
- **Aurora cold start** — first message after auto-pause adds ~10–15s. Lambda timeout is 30s, which covers it.
- **KB IAM role gotcha** — needs `rds:DescribeDBClusters` (not just `rds-data:*`). Without it, `aws_bedrockagent_knowledge_base` creation fails with a 403 from the validation phase even though the actual Data API connection would have worked.
- **Security group descriptions are ASCII-only** — AWS rejects non-ASCII chars (em-dashes, smart quotes). Plain `-` only in the `description` field.
- **Two-pass `terraform apply`** — the Lambda env-var update referencing `aws_bedrockagent_knowledge_base.main.id` fails on first apply with `Provider produced inconsistent final plan` (the count of `environment` blocks goes from 0 to 1 mid-apply). Re-run `terraform apply` immediately and it succeeds. Do not try to "fix" this in code — it's a known AWS provider limitation.
- **Document workflow** — user uploads files to the docs bucket (`terraform output -raw docs_bucket_name`), then runs `scripts/sync_kb.py <kb-id> <region>` to trigger ingestion. Required after every doc change.
- **Reply-language drift** — Nova Lite sometimes mirrors the language of retrieved chunks instead of the user's input language. Listed under "Future phases" in README; would be fixed by adding explicit language detection + instruction in `lambda/handler.py`.

## Scripts

All scripts in `scripts/` are called by Terraform provisioners and are idempotent (check before creating):

| Script | Called from | Purpose |
|--------|-------------|---------|
| `build_bot_locale.py` | `null_resource.build_locales` in `lex.tf` | Builds a Lex locale and polls until `Built` |
| `create_bot_alias.py` | `data "external" "bot_alias"` in `lex.tf` | Creates or queries the `live` alias, returns ARN as JSON |
| `associate_lex_bot.py` | `null_resource.associate_lex` in `connect.tf` | Associates the Lex V2 alias with the Connect instance |
| `init_aurora_schema.py` | `null_resource.init_aurora_schema` in `rag.tf` | Creates pgvector + Bedrock KB schema via RDS Data API (idempotent) |
| `sync_kb.py` | run manually after uploading docs | Triggers Bedrock KB ingestion job and polls until complete |

## Terraform provider

AWS provider `~> 5.0`. Supported Lex V2 Terraform resources: `aws_lexv2models_bot`, `aws_lexv2models_bot_locale`, `aws_lexv2models_bot_version`, `aws_lexv2models_intent`, `aws_lexv2models_slot`, `aws_lexv2models_slot_type`. No `aws_lexv2models_bot_alias`.