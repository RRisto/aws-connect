#!/usr/bin/env python3
"""Idempotently associate a Lex V2 bot alias with an Amazon Connect instance."""
import subprocess
import sys


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()


def main():
    instance_id, alias_arn, region = sys.argv[1], sys.argv[2], sys.argv[3]

    # Check if already associated
    existing = run([
        "aws", "connect", "list-bots",
        "--instance-id", instance_id,
        "--lex-version", "V2",
        "--region", region,
        "--query", f"LexBots[?LexV2Bot.AliasArn=='{alias_arn}'].LexV2Bot.AliasArn | [0]",
        "--output", "text",
    ])

    if existing and existing != "None":
        print(f"Already associated: {alias_arn}", flush=True)
        sys.exit(0)

    subprocess.run(
        [
            "aws", "connect", "associate-bot",
            "--instance-id", instance_id,
            "--lex-v2-bot", f"AliasArn={alias_arn}",
            "--region", region,
        ],
        check=True,
    )
    print(f"Associated {alias_arn} with Connect instance {instance_id}", flush=True)


if __name__ == "__main__":
    main()