# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

AWS Connect chatbot (chat only, no voice) for Estonian, English, and Russian, built with Terraform + Lambda.

Architecture: **Amazon Connect → Lex V2 → Lambda**

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

## Scripts

All scripts in `scripts/` are called by Terraform provisioners and are idempotent (check before creating):

| Script | Called from | Purpose |
|--------|-------------|---------|
| `build_bot_locale.py` | `null_resource.build_locales` in `lex.tf` | Builds a Lex locale and polls until `Built` |
| `create_bot_alias.py` | `data "external" "bot_alias"` in `lex.tf` | Creates or queries the `live` alias, returns ARN as JSON |
| `associate_lex_bot.py` | `null_resource.associate_lex` in `connect.tf` | Associates the Lex V2 alias with the Connect instance |

## Terraform provider

AWS provider `~> 5.0`. Supported Lex V2 Terraform resources: `aws_lexv2models_bot`, `aws_lexv2models_bot_locale`, `aws_lexv2models_bot_version`, `aws_lexv2models_intent`, `aws_lexv2models_slot`, `aws_lexv2models_slot_type`. No `aws_lexv2models_bot_alias`.