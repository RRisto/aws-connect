# AWS Connect Chatbot

Chat-only customer-facing bot built on Amazon Connect + Lex V2 + Lambda + Bedrock, with RAG over a document corpus. Supports Estonian, English, and Russian. No voice — text/chat only.

```
Amazon Connect (chat)
    └── Amazon Lex V2 (intent detection)
            └── AWS Lambda (fulfillment)
                    ├── Bedrock Knowledge Base (Retrieve)  ─── Aurora pgvector
                    │                                          ↑
                    │                                       S3 docs bucket
                    │                                       (PDF / MD / TXT / DOCX)
                    └── Amazon Bedrock Nova Lite (LLM, grounded on retrieved chunks)
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with credentials
- Python 3.11+ with `boto3` (`pip install boto3`)
- An AWS account with billing enabled (Aurora Serverless v2 and Bedrock are not in the free tier)

---

## Step 1 — Enable Bedrock models (one-time, per region)

As of late 2025, AWS retired the **Model access** page. Serverless foundation models — including the two this project uses — are now auto-enabled the **first time you invoke them** in a given account + region. There's no opt-in form to fill out.

What you need to do:

1. Make sure your AWS account is in **eu-central-1 (Frankfurt)** (top-right region selector).
2. Trigger a one-time invocation of each model so AWS provisions account-level access. Easiest way is from your terminal:

   ```bash
   # Nova Lite (chat responses)
   aws bedrock-runtime invoke-model \
     --region eu-central-1 \
     --model-id eu.amazon.nova-lite-v1:0 \
     --body '{"messages":[{"role":"user","content":[{"text":"hi"}]}],"inferenceConfig":{"maxTokens":10}}' \
     --cli-binary-format raw-in-base64-out /tmp/nova.json && cat /tmp/nova.json

   # Cohere Embed Multilingual v3 (RAG embeddings)
   aws bedrock-runtime invoke-model \
     --region eu-central-1 \
     --model-id cohere.embed-multilingual-v3 \
     --body '{"texts":["test"],"input_type":"search_document"}' \
     --cli-binary-format raw-in-base64-out /tmp/cohere.json && echo OK
   ```

   Both calls should return without `AccessDeniedException`. If a call fails, the error message will tell you what to do (e.g. for Anthropic models you'd be asked to submit use-case details — Nova Lite and Cohere don't require this).

3. **Anthropic / Marketplace models only:** if you ever switch to an Anthropic model (Claude) you'll be prompted on first invocation to submit a short use-case form. For Marketplace-distributed models, an IAM principal with Marketplace permissions must do the first invocation. Neither applies to Nova Lite or Cohere Embed Multilingual.

> If you skip this step and run Terraform first, the apply will succeed (it doesn't invoke the models), but the **first chat message** and the **first KB ingestion** will fail with `AccessDeniedException` until the one-shot invocation above is done. Re-run `python3 scripts/sync_kb.py …` after enabling.

---

## Step 2 — Configure AWS credentials

```bash
aws configure
# or set environment variables:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=eu-central-1
```

**Recommended (least-privilege builder user):** instead of using your admin keys for every apply, run the bootstrap once with admin creds to mint a scoped IAM user:

```bash
cd terraform/bootstrap
terraform init && terraform apply
terraform output access_key_id
terraform output -raw secret_access_key
# Reconfigure the CLI with those keys before continuing
```

The bootstrap policy grants exactly what `terraform/infra/` needs: Connect, Lex, Lambda, Bedrock, RDS, Secrets Manager, EC2 (VPC), S3, IAM (scoped to `connect-bot-*` roles), CloudWatch Logs.

---

## Step 3 — Deploy core infrastructure

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
10. RAG stack: S3 docs bucket, VPC, Aurora Serverless v2 (pgvector), Bedrock Knowledge Base with Cohere multilingual embeddings — **adds ~5 min**

Full apply time: **~25–30 minutes**.

If the apply fails partway through (e.g. Cohere access wasn't granted yet), fix the prerequisite and re-run `terraform apply` — Terraform is incremental and will only create what's missing.

**Expected: the first apply ends with one error.** The Lambda environment block update fails on first apply with `Provider produced inconsistent final plan` because the new `KNOWLEDGE_BASE_ID` env var references the KB ID, which Terraform only learns mid-apply. **Just re-run `terraform apply`** — the second apply succeeds in ~30 s (the KB ID is now in state and the env var update commits cleanly).

---

## Step 4 — Configure FallbackIntent (required after first deploy)

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

## Step 5 — Create a Connect admin user

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

## Step 6 — Load RAG documents

Drop documents (PDF, MD, TXT, HTML, DOCX — multilingual mix is fine) into the docs bucket, then trigger an ingestion job. The bot will retrieve relevant chunks for every user message.

```bash
# 1. Create a local docs/ folder and put your files in it
mkdir -p docs
# (copy your PDFs / .md / .txt / .docx into docs/)

# 2. Upload to the auto-provisioned bucket
aws s3 cp ./docs/ s3://$(terraform output -raw docs_bucket_name)/ --recursive

# 3. Tell Bedrock to ingest them (chunk → embed with Cohere multilingual → write to Aurora pgvector)
python3 ../../scripts/sync_kb.py $(terraform output -raw knowledge_base_id) eu-central-1
```

First sync takes 1–5 min depending on document count. Re-run `sync_kb.py` whenever you add, change, or remove files.

**Where to get LHV documents:** the easiest path is to "Save as PDF" the relevant LHV pages (FAQ, fees, products) from your browser, drop them into `docs/`, and re-sync. Web-crawler ingestion is not configured (would require a separate Bedrock data source).

**How retrieval works:** the Lambda calls `bedrock-agent-runtime:Retrieve` with the user's message, gets the top 5 chunks, injects them into the Nova Lite system prompt, and instructs the model to answer only from that context. Cohere multilingual embeddings allow cross-lingual retrieval — a query in Estonian will match documents written in English or Russian.

**Cost note:** Aurora Serverless v2 is configured with `min_capacity = 0` so it auto-pauses after 5 min of inactivity. Idle cost is ~$0; the first message after a pause adds ~10–15 s cold start (within the 30 s Lambda timeout).

---

## Step 7 — Test the bot

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

### Verify RAG is working

After loading a document, ask something only that document could answer (and the same question in another language):

```bash
# English query
aws lambda invoke --function-name connect-bot-handler \
  --payload '{"sessionState":{"intent":{"name":"FallbackIntent","state":"InProgress"}},"inputTranscript":"<a question answerable from your docs>","invocationSource":"FulfillmentCodeHook"}' \
  --cli-binary-format raw-in-base64-out response.json && cat response.json

# Same question in Estonian — should retrieve the same English chunks
aws lambda invoke --function-name connect-bot-handler \
  --payload '{"sessionState":{"intent":{"name":"FallbackIntent","state":"InProgress"}},"inputTranscript":"<sama küsimus eesti keeles>","invocationSource":"FulfillmentCodeHook"}' \
  --cli-binary-format raw-in-base64-out response.json && cat response.json
```

Then ask something **not** in your documents — the bot should say it doesn't know and offer to escalate, instead of hallucinating.

Watch the Lambda logs to confirm retrieval ran:

```bash
aws logs tail /aws/lambda/connect-bot-handler --follow --region eu-central-1
# Look for: "Retrieved N chunks for query"
```

---

## Updating the bot

**Change the prompt or response logic** — edit `lambda/handler.py`, then:
```bash
cd terraform/infra && terraform apply
```
Terraform detects source changes via `source_code_hash` and redeploys Lambda automatically. No Connect instance reprovisioning.

**Add a new intent** — add an `aws_lexv2models_intent` resource in `terraform/infra/lex.tf`, re-apply, then run the Step 4 scripts to rebuild and version the bot.

**Add / change RAG documents** — drop or replace files in the docs bucket and re-run the Step 6 commands:
```bash
aws s3 cp ./docs/ s3://$(terraform output -raw docs_bucket_name)/ --recursive
python3 ../../scripts/sync_kb.py $(terraform output -raw knowledge_base_id) eu-central-1
```
To delete a doc, `aws s3 rm s3://…/file.pdf`, then re-sync — Bedrock removes its chunks from Aurora during the next ingestion job.

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

The S3 docs bucket has `force_destroy = true`, so any uploaded documents are deleted with the bucket. Aurora is destroyed with `skip_final_snapshot = true` — there is no backup retained. If you want to keep your data, take a manual snapshot or `aws s3 sync` the bucket out before destroying.

---

## Costs

Everything except the Aurora storage layer is pay-per-use, so an idle deployment is cheap. Approximate **idle** cost (no chats, Aurora auto-paused):

| Resource | Idle cost | Notes |
| --- | --- | --- |
| Aurora Serverless v2 compute | **$0** | `min_capacity = 0` auto-pauses after 5 min idle. Cold start ~10–15 s on the next query. |
| Aurora cluster storage | ~$0.03/day | ~10 GB minimum at $0.10/GB-month |
| Aurora backup storage | ~$0.01/day | Empty cluster |
| Secrets Manager (Aurora password) | $0.013/day | $0.40/secret-month, fixed |
| S3 (docs bucket + tfstate) | <$0.001/day | Tiny, depends on doc size |
| Bedrock Knowledge Base | $0 | Pay only per `Retrieve` call (~$0.0001 each) |
| Lambda / Lex / Bedrock Nova Lite | $0 | Per-invocation only |
| Amazon Connect instance | $0 | Per chat-minute only when used |
| VPC / subnets / SG | $0 | No NAT gateway provisioned |

**Total idle: ~$0.05–0.10/day, ~$1.50–3/month.** Safe to leave running between testing sessions.

**Per-chat cost** (rough, 200-token user turn + 5 retrieved chunks + 200-token reply):
- Bedrock KB Retrieve: ~$0.0001
- Cohere embed of the query: ~$0.0001
- Nova Lite inference: ~$0.0003
- Lex text request: ~$0.004
- Connect chat minute: ~$0.004
- **Per message: ~$0.008** (most of it is Connect + Lex, not the LLM)

**Watch out for:** if you query frequently enough that Aurora never auto-pauses (>1 query per 5 min sustained), compute kicks in at ~$0.06/hour per ACU = ~$1.44/day. A casual demo won't trigger this; an automated load test will.

**Bedrock ingestion (one-time per re-sync):** Cohere Embed Multilingual v3 charges ~$0.0001 per 1k tokens. A 200 KB PDF is ~50–80k tokens, so each `sync_kb.py` run on a single doc is well under $0.01.

---

## Architecture notes

- **Single Lex locale (`en_US`)** — `ru_RU` and `et_ET` cannot be built (no supported NLU training data). Language is detected in Lambda by inspecting the message text: Cyrillic → Russian, Estonian characters (äöüõ) → Estonian, otherwise English.
- **LLM model** — Amazon Bedrock Nova Lite (`eu.amazon.nova-lite-v1:0` inference profile for EU regions). No Anthropic account required.
- **`aws_lexv2models_bot_alias`** — does not exist in the Terraform AWS provider (5.x). Managed via `scripts/create_bot_alias.py`.
- **`aws_connect_bot_association`** — only supports Lex V1. Lex V2 association handled via `scripts/associate_lex_bot.py`.
- **`AMAZON.FallbackIntent`** — cannot be fully managed via Terraform or the AWS CLI (name conflicts). Configured via `scripts/enable_fallback_intent.py` using boto3 after each deploy.
- **Contact flow** — created via `scripts/create_contact_flow.py` (boto3) rather than `aws_connect_contact_flow` Terraform resource, because the resource's error messages omit the `problems` array needed for debugging.
- **Vector store** — Aurora Serverless v2 + pgvector on PostgreSQL 16.13 (auto-pause to 0 ACU after 5 min idle). Chosen over OpenSearch Serverless ($345/mo minimum) for cost. Bedrock reaches Aurora via the RDS Data API (`enable_http_endpoint = true`), so Lambda stays out of the VPC.
- **Embeddings** — Cohere Embed Multilingual v3 (1024 dim) — strongest cross-lingual coverage for Estonian/Russian/English. Titan Embeddings v2 was rejected because cross-lingual retrieval is weaker.
- **Retrieve vs RetrieveAndGenerate** — Lambda uses `Retrieve` and runs Nova Lite itself, so the multilingual system prompt and reply tuning stay under our control. `RetrieveAndGenerate` would override that with the KB's default prompt template.
- **Aurora schema** — Bedrock KB requires a specific table layout (`bedrock_integration.bedrock_kb` with `id`/`embedding`/`chunks`/`metadata`). Created by `scripts/init_aurora_schema.py` via the Data API before the KB is provisioned.
- **Chunking** — fixed-size, 300 tokens with 20% overlap (`rag.tf` → `vector_ingestion_configuration`). To switch to hierarchical or semantic chunking, or plug in a custom Lambda chunker, change `chunking_strategy` in that block.
- **KB IAM role** — needs `rds:DescribeDBClusters` in addition to `rds-data:ExecuteStatement` and `secretsmanager:GetSecretValue`, otherwise `aws_bedrockagent_knowledge_base` creation fails with a 403 even though the underlying connection would have worked.
- **Bedrock model access** — the AWS console "Model access" page was retired in late 2025; serverless models auto-enable on first invocation. Step 1 above triggers this with a one-shot CLI call rather than relying on the console UI.
- **Two-pass apply** — first `terraform apply` fails on the Lambda environment block update because the `aws_bedrockagent_knowledge_base.main.id` reference resolves only mid-apply, and the AWS provider can't reconcile the env-block count change ("Provider produced inconsistent final plan"). Re-running `terraform apply` immediately afterward succeeds because the KB ID is now in state.

## Future phases

- Custom chunking via Bedrock KB Lambda transformer (when fixed-size 300/20 stops being good enough)
- Human escalation (transfer to agent queue)
- Voice support (add Polly IAM policy to the Lex role)
- Web crawler data source (currently S3 upload only)
- Reranking + answer citations
- Reply-language enforcement (currently the LLM sometimes mirrors the retrieved-context language instead of the user's language)
