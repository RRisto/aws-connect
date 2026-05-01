import json
import logging
import os
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SYSTEM_PROMPT = """You are a helpful customer service assistant.

Rules:
- Always reply in the same language the customer writes in (Estonian, Russian, or English only).
- Be concise and friendly.
- If you don't know something specific about the company, say so politely and offer to connect them with a human agent.
- Never make up prices, policies, or product details."""

GROUNDING_INSTRUCTION = """\

Use the following context to answer when relevant. If the context does not contain the answer, say you don't know and offer to connect the customer with a human agent. Do not invent details beyond the context.

Context:
{context}"""

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "eu.amazon.nova-lite-v1:0")
KNOWLEDGE_BASE_ID = os.environ.get("KNOWLEDGE_BASE_ID")
REGION = os.environ.get("AWS_REGION", "eu-central-1")
TOP_K = int(os.environ.get("RAG_TOP_K", "5"))

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
bedrock_agent = boto3.client("bedrock-agent-runtime", region_name=REGION)


def retrieve_context(query: str) -> str:
    if not KNOWLEDGE_BASE_ID or not query.strip():
        return ""
    try:
        result = bedrock_agent.retrieve(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {"numberOfResults": TOP_K},
            },
        )
        chunks = [r["content"]["text"] for r in result.get("retrievalResults", [])]
        logger.info("Retrieved %d chunks for query", len(chunks))
        return "\n---\n".join(chunks)
    except Exception:
        logger.exception("Retrieve failed; falling back to no context")
        return ""


def lambda_handler(event, context):
    user_text = event.get("inputTranscript", "")
    retrieved = retrieve_context(user_text)
    system_prompt = SYSTEM_PROMPT + (GROUNDING_INSTRUCTION.format(context=retrieved) if retrieved else "")

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps({
            "system": [{"text": system_prompt}],
            "messages": [{"role": "user", "content": [{"text": user_text}]}],
            "inferenceConfig": {"maxTokens": 300},
        }),
    )

    reply = json.loads(response["body"].read())["output"]["message"]["content"][0]["text"]

    return {
        "sessionState": {
            "dialogAction": {"type": "ElicitIntent"},
        },
        "messages": [{"contentType": "PlainText", "content": reply}],
    }
