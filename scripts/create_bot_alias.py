#!/usr/bin/env python3
"""
Idempotent Lex V2 bot alias creator.
Called by Terraform data "external" — reads JSON query from stdin, writes JSON result to stdout.
"""
import json
import subprocess
import sys


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()


def main():
    query = json.load(sys.stdin)
    bot_id = query["bot_id"]
    bot_version = query["bot_version"]
    lambda_arn = query["lambda_arn"]
    region = query["region"]

    # Check if alias named 'live' already exists
    existing = run([
        "aws", "lexv2-models", "list-bot-aliases",
        "--bot-id", bot_id,
        "--region", region,
        "--query", "botAliasSummaries[?botAliasName=='live'].botAliasId | [0]",
        "--output", "text",
    ])

    if existing and existing != "None":
        alias_id = existing
    else:
        locale_settings = {
            "en_US": {
                "enabled": True,
                "codeHookSpecification": {
                    "lambdaCodeHook": {
                        "lambdaARN": lambda_arn,
                        "codeHookInterfaceVersion": "1.0",
                    }
                },
            }
        }
        alias_id = run([
            "aws", "lexv2-models", "create-bot-alias",
            "--bot-id", bot_id,
            "--bot-alias-name", "live",
            "--bot-version", bot_version,
            "--bot-alias-locale-settings", json.dumps(locale_settings),
            "--region", region,
            "--query", "botAliasId",
            "--output", "text",
        ])

    account = run(["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"])
    alias_arn = f"arn:aws:lex:{region}:{account}:bot-alias/{bot_id}/{alias_id}"

    print(json.dumps({"alias_id": alias_id, "alias_arn": alias_arn}))


if __name__ == "__main__":
    main()