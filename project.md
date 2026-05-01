# AWS Connect Chatbot Project

## Goal
Build a simple but expandable customer-facing chatbot using Amazon Connect,
supporting Estonian, English, and Russian (text/chat only initially).

## Architecture
Amazon Connect (chat channel)
    └── Amazon Lex V2 (NLU / intent handling)
            └── AWS Lambda (business logic)

## Language Support
| Language | Locale  |
|----------|---------|
| Estonian | et-EE   |
| English  | en_US   |
| Russian  | ru_RU   |

## Infrastructure as Code
All infrastructure managed via **Terraform** (AWS provider ~> 5.0).
No Helm/Kubernetes — fully serverless/managed services.

## Phased Approach

### Phase 1 — IAM Bootstrap (admin credentials, one-time)
- Create least-privilege IAM user for all subsequent work
- Services covered: Connect, Lex V2, Lambda, IAM (scoped), CloudWatch, S3

### Phase 2 — Core Infrastructure
- Amazon Connect instance
- Lex V2 bot with 3 locales
- Basic intents: Greet, Fallback
- Lambda function for business logic
- Connect Contact Flow wiring it together

### Phase 3 — Testing
- Test chat in all 3 languages via Connect test chat UI

### Future Phases
- RAG via Amazon Bedrock + Knowledge Base
- Human escalation (transfer to agent queue)
- Voice support

## Repo Structure (planned)
terraform/
├── bootstrap/      # IAM user (run once with admin creds)
├── connect/        # Connect instance + contact flows
├── lex/            # Lex V2 bot + intents
└── lambda/         # Lambda function code + packaging




## Task: Terraform IAM Bootstrap for AWS Connect Chatbot Project

Create Terraform configuration files to provision a least-privilege IAM user
for building an Amazon Connect chatbot. The project will later include Lex V2,
Lambda, and a Connect instance.

### Files to create:
- `providers.tf`
- `variables.tf`
- `main.tf`
- `outputs.tf`

### Requirements:

**Provider:**
- AWS provider, region configurable via variable (default: `eu-central-1`)

**IAM User:**
- Username configurable via variable (default: `connect-bot-builder`)
- Programmatic access only (access key + secret)

**IAM Policy (least privilege):**
Attach an inline or managed policy granting access to:
- `lex:*` (Lex V2 only, i.e. `us-east-1` scoped if needed)
- `connect:*`
- `lambda:*`
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole` (scoped to bot-related roles)
- `logs:*` (CloudWatch Logs)
- `s3:*` (for Lambda deployment packages)

**Outputs:**
- Access key ID
- Secret access key (marked sensitive)

### Notes:
- Use Terraform ~> 5.0 AWS provider
- No backend config needed (local state is fine for bootstrap)
- Keep it simple and well-commented