"""Custom resource that writes runtime configuration into the Meta app bucket."""

from __future__ import annotations

import json

import boto3


s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")
cloudfront = boto3.client("cloudfront")


def handler(event: dict, _context: object) -> dict:
    props = event["ResourceProperties"]
    physical_id = f"{props['Bucket']}/config.js"
    if event.get("RequestType") == "Delete":
        return {"PhysicalResourceId": physical_id}

    api_key = secrets.get_secret_value(SecretId=props["SecretArn"])["SecretString"]
    config = {
        "apiBaseUrl": props["ApiUrl"],
        "apiKey": api_key,
        "sessionId": "training-001",
    }
    body = "window.WIREJAC = " + json.dumps(config, separators=(",", ":")) + ";\n"
    s3.put_object(
        Bucket=props["Bucket"],
        Key="config.js",
        Body=body.encode("utf-8"),
        ContentType="application/javascript; charset=utf-8",
        CacheControl="no-store, max-age=0",
    )
    invalidation = cloudfront.create_invalidation(
        DistributionId=props["DistributionId"],
        InvalidationBatch={
            "Paths": {"Quantity": 1, "Items": ["/config.js"]},
            "CallerReference": event["RequestId"],
        },
    )
    return {
        "PhysicalResourceId": physical_id,
        "Data": {"InvalidationId": invalidation["Invalidation"]["Id"]},
    }
