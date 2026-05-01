#!/usr/bin/env python3
"""
Create the chat contact flow via boto3.
Called by Terraform data "external" — reads JSON query from stdin, writes JSON result to stdout.
InvalidContactFlowException includes a 'problems' array with specific messages;
boto3 exposes it so we can print the real error instead of the generic wrapper.
"""
import json
import sys
import boto3
from botocore.exceptions import ClientError

FLOW_CONTENT_TEMPLATE = {
    "Version": "2019-10-30",
    "StartAction": "b6f2c3a4-d5e6-7f80-9a1b-2c3d4e5f6a7b",
    "Actions": [
        {
            "Identifier": "b6f2c3a4-d5e6-7f80-9a1b-2c3d4e5f6a7b",
            "Type": "ConnectParticipantWithLexBot",
            "Parameters": {
                "Text": "Hello! How can I help you?",
                "LexV2Bot": {
                    "AliasArn": "__ALIAS_ARN__"
                }
            },
            "Transitions": {
                "NextAction": "e1f2a3b4-c5d6-7e80-9f1a-2b3c4d5e6f7a",
                "Errors": [
                    {
                        "NextAction": "e1f2a3b4-c5d6-7e80-9f1a-2b3c4d5e6f7a",
                        "ErrorType": "NoMatchingError"
                    },
                    {
                        "NextAction": "e1f2a3b4-c5d6-7e80-9f1a-2b3c4d5e6f7a",
                        "ErrorType": "NoMatchingCondition"
                    }
                ]
            }
        },
        {
            "Identifier": "e1f2a3b4-c5d6-7e80-9f1a-2b3c4d5e6f7a",
            "Type": "DisconnectParticipant",
            "Parameters": {},
            "Transitions": {}
        }
    ]
}

FLOW_NAME = "connect-bot-chat-flow"


def main():
    query = json.load(sys.stdin)
    instance_id = query["instance_id"]
    alias_arn = query["alias_arn"]
    region = query["region"]

    client = boto3.client("connect", region_name=region)

    content = json.dumps(FLOW_CONTENT_TEMPLATE).replace("__ALIAS_ARN__", alias_arn)

    # Check if flow already exists — update its content if so (alias ARN may have changed)
    paginator = client.get_paginator("list_contact_flows")
    for page in paginator.paginate(InstanceId=instance_id):
        for flow in page["ContactFlowSummaryList"]:
            if flow["Name"] == FLOW_NAME:
                client.update_contact_flow_content(
                    InstanceId=instance_id,
                    ContactFlowId=flow["Id"],
                    Content=content,
                )
                print(json.dumps({"flow_id": flow["Id"]}), flush=True)
                return

    try:
        resp = client.create_contact_flow(
            InstanceId=instance_id,
            Name=FLOW_NAME,
            Type="CONTACT_FLOW",
            Content=content,
        )
        print(json.dumps({"flow_id": resp["ContactFlowId"]}), flush=True)

    except ClientError as e:
        code = e.response["Error"]["Code"]
        msg = e.response["Error"]["Message"]
        # InvalidContactFlowException carries a 'problems' list with real detail
        problems = e.response.get("problems", [])
        print(f"AWS error {code}: {msg}", file=sys.stderr)
        for p in problems:
            print(f"  Problem: {p.get('message', p)}", file=sys.stderr)
        print(f"  Full response: {json.dumps(e.response, default=str)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
