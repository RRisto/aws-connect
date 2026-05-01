#!/usr/bin/env python3
"""Build a Lex V2 bot locale and poll until it reaches Built status."""
import subprocess
import sys
import time


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()


def main():
    bot_id, locale_id, region = sys.argv[1], sys.argv[2], sys.argv[3]

    print(f"Building locale {locale_id}...", flush=True)
    subprocess.run(
        [
            "aws", "lexv2-models", "build-bot-locale",
            "--bot-id", bot_id,
            "--bot-version", "DRAFT",
            "--locale-id", locale_id,
            "--region", region,
        ],
        check=True,
    )

    for attempt in range(30):
        status = run([
            "aws", "lexv2-models", "describe-bot-locale",
            "--bot-id", bot_id,
            "--bot-version", "DRAFT",
            "--locale-id", locale_id,
            "--region", region,
            "--query", "botLocaleStatus",
            "--output", "text",
        ])
        print(f"  [{attempt + 1}/30] {locale_id} status: {status}", flush=True)
        if status in ("Built", "ReadyExpressTesting"):
            sys.exit(0)
        time.sleep(10)

    print(f"ERROR: Timed out waiting for {locale_id} to build", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()