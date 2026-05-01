#!/usr/bin/env python3
"""Delete the Lex V2 'live' bot alias by name. Idempotent."""
import subprocess
import sys
import json


def main():
    bot_id, alias_name_or_id, region = sys.argv[1], sys.argv[2], sys.argv[3]

    # Look up alias ID by name if a name (not an ID) was passed
    result = subprocess.run(
        ["aws", "lexv2-models", "list-bot-aliases",
         "--bot-id", bot_id, "--region", region,
         "--query", f"botAliasSummaries[?botAliasName=='{alias_name_or_id}'].botAliasId | [0]",
         "--output", "text"],
        capture_output=True, text=True,
    )
    alias_id = result.stdout.strip()
    if not alias_id or alias_id == "None":
        print(f"Alias '{alias_name_or_id}' not found, skipping")
        return

    r = subprocess.run(
        ["aws", "lexv2-models", "delete-bot-alias",
         "--bot-id", bot_id, "--bot-alias-id", alias_id, "--region", region],
        capture_output=True,
    )
    if r.returncode == 0:
        print(f"Deleted alias {alias_id}")
    elif b"ResourceNotFoundException" in r.stderr or b"does not exist" in r.stderr:
        print(f"Alias already gone, skipping")
    else:
        print(r.stderr.decode(), file=sys.stderr)
        sys.exit(r.returncode)


if __name__ == "__main__":
    main()
