import json
import boto3
from datetime import datetime

s3 = boto3.client("s3")

def lambda_handler(event, context):
    bucket = event.get("bucket")
    key = event.get("key")
    year = event.get("year")
    month = event.get("month")
    status = event.get("status")

    metadata = {
        "bucket": bucket,
        "key": key,
        "year": year,
        "month": month,
        "status": status,
        "processed_at": datetime.utcnow().isoformat()
    }

    metadata_key = f"metadata/year={year}/month={month}/{key.replace('.csv', '.json')}"

    s3.put_object(
        Bucket=bucket,
        Key=metadata_key,
        Body=json.dumps(metadata),
        ContentType="application/json"
    )

    print(f"Metadata written to s3://{bucket}/{metadata_key}")

    return {
        "status": "metadata_written",
        "metadata_key": metadata_key
    }