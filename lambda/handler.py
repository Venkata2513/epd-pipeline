import json
import boto3

stepfunctions = boto3.client("stepfunctions")

def lambda_handler(event, context):
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    key = detail.get("object", {}).get("key")

    print(f"Received file: {key}")

    response = stepfunctions.start_execution(
        stateMachineArn="arn:aws:states:eu-west-2:258180561900:stateMachine:epd-pipeline-dev",
        input=json.dumps({
            "bucket": bucket,
            "key": key
        })
    )

    print("Step Function started:", response["executionArn"])

    return {
        "statusCode": 200
    }