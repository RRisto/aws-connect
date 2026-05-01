#!/usr/bin/env python3
"""Initialise pgvector + Bedrock KB schema on Aurora via the RDS Data API.

Idempotent: safe to re-run. Bedrock KB requires this exact schema layout.
"""
import sys
import time
import boto3
from botocore.exceptions import ClientError

DDL_STATEMENTS = [
    "CREATE EXTENSION IF NOT EXISTS vector",
    "CREATE SCHEMA IF NOT EXISTS bedrock_integration",
    """CREATE TABLE IF NOT EXISTS bedrock_integration.bedrock_kb (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        embedding vector(1024),
        chunks text,
        metadata jsonb
    )""",
    """CREATE INDEX IF NOT EXISTS bedrock_kb_embedding_idx
        ON bedrock_integration.bedrock_kb
        USING hnsw (embedding vector_cosine_ops)""",
    """CREATE INDEX IF NOT EXISTS bedrock_kb_chunks_idx
        ON bedrock_integration.bedrock_kb
        USING gin (to_tsvector('simple', chunks))""",
]


def execute(client, cluster_arn, secret_arn, database, sql, retries=10):
    """Execute SQL with retry — Aurora may be cold-starting on first call."""
    for attempt in range(retries):
        try:
            return client.execute_statement(
                resourceArn=cluster_arn,
                secretArn=secret_arn,
                database=database,
                sql=sql,
            )
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            msg = str(e)
            # Aurora warming up: BadRequestException with "communications link failure",
            # "Cluster is paused", or DatabaseResumingException
            if code in ("DatabaseResumingException", "BadRequestException") and attempt < retries - 1:
                wait = min(2 ** attempt, 30)
                print(f"  Aurora warming up ({code}), retry in {wait}s...", flush=True)
                time.sleep(wait)
                continue
            print(f"SQL failed: {sql[:80]}...\n  {msg}", file=sys.stderr)
            raise


def main():
    if len(sys.argv) != 5:
        print("usage: init_aurora_schema.py <cluster-arn> <secret-arn> <database> <region>", file=sys.stderr)
        sys.exit(2)

    cluster_arn, secret_arn, database, region = sys.argv[1:5]
    client = boto3.client("rds-data", region_name=region)

    print(f"Initialising schema on {cluster_arn}", flush=True)
    for sql in DDL_STATEMENTS:
        first_line = sql.strip().split("\n")[0]
        print(f"  {first_line}", flush=True)
        execute(client, cluster_arn, secret_arn, database, sql)

    print("Schema ready.")


if __name__ == "__main__":
    main()
