#!/usr/bin/env python3
"""Trigger Bedrock KB ingestion for the S3 data source and poll until done.

Run after uploading new/changed files to the docs bucket.
"""
import sys
import time
import boto3


def main():
    if len(sys.argv) != 3:
        print("usage: sync_kb.py <knowledge-base-id> <region>", file=sys.stderr)
        sys.exit(2)

    kb_id, region = sys.argv[1], sys.argv[2]
    client = boto3.client("bedrock-agent", region_name=region)

    data_sources = client.list_data_sources(knowledgeBaseId=kb_id)["dataSourceSummaries"]
    if not data_sources:
        print("No data sources attached to this KB.", file=sys.stderr)
        sys.exit(1)
    ds_id = data_sources[0]["dataSourceId"]

    print(f"Starting ingestion job (data source {ds_id})...", flush=True)
    job = client.start_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id)
    job_id = job["ingestionJob"]["ingestionJobId"]

    while True:
        status = client.get_ingestion_job(
            knowledgeBaseId=kb_id, dataSourceId=ds_id, ingestionJobId=job_id
        )["ingestionJob"]
        state = status["status"]
        print(f"  status: {state}", flush=True)
        if state == "COMPLETE":
            stats = status.get("statistics", {})
            print(f"Done. Documents scanned={stats.get('numberOfDocumentsScanned', 0)}, "
                  f"indexed={stats.get('numberOfNewDocumentsIndexed', 0)}, "
                  f"failed={stats.get('numberOfDocumentsFailed', 0)}")
            return
        if state in ("FAILED", "STOPPED"):
            print(f"Job ended with status {state}: {status.get('failureReasons', [])}", file=sys.stderr)
            sys.exit(1)
        time.sleep(10)


if __name__ == "__main__":
    main()
