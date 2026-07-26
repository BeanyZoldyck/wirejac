"""Write Meta app config.js with the resolved shared API key."""

from __future__ import annotations

import time
from typing import Any

import boto3

s3 = boto3.client("s3")
sm = boto3.client("secretsmanager")
cloudfront = boto3.client("cloudfront")


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    request_type = event.get("RequestType", "Create")
    props = event["ResourceProperties"]
    physical_id = "wirejac-meta-app-config-js"

    if request_type == "Delete":
        return {"PhysicalResourceId": physical_id}

    secret = sm.get_secret_value(SecretId=props["SecretArn"])["SecretString"]
    api_url = props["ApiUrl"].rstrip("/") + "/"
    body = (
        "window.WIREJAC = {\n"
        f'  apiBaseUrl: "{api_url}",\n'
        f'  apiKey: "{secret}",\n'
        '  sessionId: "training-001"\n'
        "};\n"
    )
    s3.put_object(
        Bucket=props["Bucket"],
        Key="config.js",
        Body=body.encode("utf-8"),
        ContentType="application/javascript",
        CacheControl="no-cache, no-store, must-revalidate",
    )

    distribution_id = props.get("DistributionId") or ""
    if distribution_id:
        cloudfront.create_invalidation(
            DistributionId=distribution_id,
            InvalidationBatch={
                "Paths": {"Quantity": 1, "Items": ["/config.js"]},
                "CallerReference": f"wirejac-config-{int(time.time())}",
            },
        )

    return {
        "PhysicalResourceId": physical_id,
        "Data": {"ApiUrl": api_url},
    }
