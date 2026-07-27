"""Narrow host adapter for publishing the validated mini-app to CloudFront."""

import from typing { cast }

::py::
import json
import os
import pathlib
import subprocess
import urllib.request

_PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
_CLIENT_ROOT = _PROJECT_ROOT / "workspace" / "client"


def _command(argv, timeout=180):
    completed = subprocess.run(
        argv,
        cwd=_PROJECT_ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=os.environ.copy(),
    )
    if completed.returncode != 0:
        detail = (completed.stdout + "\n" + completed.stderr).strip()[-4000:]
        raise RuntimeError(f"{' '.join(argv[:3])} failed: {detail}")
    return completed.stdout


def _hosting_outputs():
    stack = os.environ.get("WIREJAC_STACK", "WirejacDevStack")
    payload = json.loads(_command([
        "aws", "cloudformation", "describe-stacks",
        "--stack-name", stack, "--output", "json",
    ], timeout=30))
    outputs = payload["Stacks"][0].get("Outputs", [])

    def value(fragment):
        for output in outputs:
            if fragment in output.get("OutputKey", ""):
                return output.get("OutputValue", "")
        raise RuntimeError(f"CloudFormation output {fragment} was not found")

    return {
        "bucket": value("MetaAppBucketName"),
        "distribution_id": value("MetaAppDistributionId"),
        "url": value("MetaAppUrl"),
    }


def _deploy_frontend_cloudfront():
    for required in ["index.html", "app.js", "styles.css"]:
        if not (_CLIENT_ROOT / required).is_file():
            raise RuntimeError(f"Validated frontend is missing {required}")

    outputs = _hosting_outputs()
    _command([
        "aws", "s3", "sync", str(_CLIENT_ROOT),
        "s3://" + outputs["bucket"],
        "--delete",
        "--exclude", ".jac/*",
        "--exclude", "node_modules/*",
        "--exclude", "*.md",
        "--exclude", "package*.json",
        "--exclude", "config.js",
        "--exclude", "config.example.js",
        "--exclude", "main.jac",
        "--exclude", "jac.toml",
        "--cache-control", "no-cache",
    ])
    invalidation = json.loads(_command([
        "aws", "cloudfront", "create-invalidation",
        "--distribution-id", outputs["distribution_id"],
        "--paths", "/*", "--output", "json",
    ], timeout=30))
    invalidation_id = invalidation["Invalidation"]["Id"]
    _command([
        "aws", "cloudfront", "wait", "invalidation-completed",
        "--distribution-id", outputs["distribution_id"],
        "--id", invalidation_id,
    ], timeout=240)
    request = urllib.request.Request(
        outputs["url"] + "/",
        headers={"User-Agent": "WireJac frontend verifier"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        if response.status != 200:
            raise RuntimeError(f"CloudFront verification returned HTTP {response.status}")
        body = response.read(4096).decode("utf-8", errors="replace")
    if "<html" not in body.lower() and "<!doctype html" not in body.lower():
        raise RuntimeError("CloudFront verification did not return the mini-app HTML")
    return {
        "url": outputs["url"],
        "bucket": outputs["bucket"],
        "distribution_id": outputs["distribution_id"],
        "invalidation_id": invalidation_id,
    }
::py::


def deploy_frontend_cloudfront() -> dict[str, str] {
    return cast(dict[str, str], _deploy_frontend_cloudfront());
}
