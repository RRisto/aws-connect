import json
import os
import boto3

SYSTEM_PROMPT = """You are a helpful customer service assistant.

Rules:
- Always reply in the same language the customer writes in (Estonian, Russian, or English only).
- Be concise and friendly.
- If you don't know something specific about the company, say so politely and offer to connect them with a human agent.
- Never make up prices, policies, or product details."""

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "eu.amazon.nova-lite-v1:0")

bedrock = boto3.client("bedrock-runtime", region_name=os.environ.get("AWS_REGION", "eu-central-1"))


def lambda_handler(event, context):
    intent = event["sessionState"]["intent"]["name"]
    user_text = event.get("inputTranscript", "")

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps({
            "system": [{"text": SYSTEM_PROMPT}],
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