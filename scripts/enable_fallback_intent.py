#!/usr/bin/env python3
"""Enable Lambda fulfillment hook on FallbackIntent by mirroring its current config."""
import boto3
import json
import sys

bot_id, region = sys.argv[1], sys.argv[2]
client = boto3.client("lexv2-models", region_name=region)

current = client.describe_intent(
    intentId="FALLBCKINT",
    botId=bot_id,
    botVersion="DRAFT",
    localeId="en_US",
)
print("Current intent:", json.dumps({k: v for k, v in current.items() if k != "ResponseMetadata"}, default=str), flush=True)

# Build update kwargs mirroring current fields, only changing fulfillmentCodeHook
kwargs = {
    "intentId": "FALLBCKINT",
    "intentName": current["intentName"],
    "botId": bot_id,
    "botVersion": "DRAFT",
    "localeId": "en_US",
    # Route directly to fulfillment (skip the initialResponse dialog hook which ends conversation)
    "initialResponseSetting": {
        "nextStep": {"dialogAction": {"type": "FulfillIntent"}},
    },
    # Fulfillment hook calls Lambda; Lambda returns ElicitIntent to keep session alive
    "fulfillmentCodeHook": {
        "enabled": True,
        "active": True,
        "postFulfillmentStatusSpecification": {
            "successNextStep": {"dialogAction": {"type": "ElicitIntent"}},
            "failureNextStep": {"dialogAction": {"type": "EndConversation"}},
            "timeoutNextStep": {"dialogAction": {"type": "EndConversation"}},
        },
    },
}
for field in ("description", "parentIntentSignature", "sampleUtterances",
              "dialogCodeHook", "intentConfirmationSetting",
              "kendraConfiguration", "inputContexts", "outputContexts",
              "qnAIntentConfiguration"):
    if field in current:
        kwargs[field] = current[field]

try:
    client.update_intent(**kwargs)
    print("FallbackIntent fulfillment hook enabled.")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
