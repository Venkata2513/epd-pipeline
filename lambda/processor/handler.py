import json
import re
import boto3
from datetime import datetime, timezone
from urllib.parse import unquote_plus

s3 = boto3.client("s3")

def log_event(level, message, **kwargs):
    print(json.dumps({
        "level": level,
        "message": message,
        **kwargs
    }))

def lambda_handler(event, context):
    bucket = event.get("bucket")
    key = unquote_plus(event.get("key", ""))

    log_event("INFO", "Processor started", bucket=bucket, key=key)

    filename = key.split("/")[-1]
    match = re.match(r"^epd_(\d{4})_(\d{2})\.csv$", filename)

    if not match:
        log_event("ERROR", "Invalid filename format", bucket=bucket, key=key)

        return {
            "status": "error",
            "message": "Invalid filename format",
            "bucket": bucket,
            "key": key
        }

    year, month = match.groups()
    processed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    run_id = f"epd-{year}-{month}"

    metadata_key = f"metadata/year={year}/month={month}/{filename.replace('.csv', '.json')}"

    metadata = {
        "run_id": run_id,
        "status": "processing_complete",
        "bucket": bucket,
        "source_key": key,
        "metadata_key": metadata_key,
        "year": year,
        "month": month,
        "processed_at": processed_at
    }

    s3.put_object(
        Bucket=bucket,
        Key=metadata_key,
        Body=json.dumps(metadata, indent=2),
        ContentType="application/json"
    )

    log_event(
        "INFO",
        "Metadata written",
        run_id=run_id,
        bucket=bucket,
        source_key=key,
        metadata_key=metadata_key
    )

    return metadata