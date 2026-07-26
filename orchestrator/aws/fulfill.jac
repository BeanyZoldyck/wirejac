"""Infrastructure fulfillment catalog.

The backend/server agent emits `InfraRequest` values. This module is the
infrastructure worker's registry: known resources that already exist in
`infrastructure/`, plus helpers to decide whether deployment must run the
AWS pipeline before the server can use durable storage.
"""

import os;

import from orchestrator.aws.contracts { InfraKind, InfraRequest }


"""Resources the infrastructure worker has already defined in CDK."""
glob FULFILLED_RESOURCES: dict[str, InfraKind] = {
    "SamplesTable": InfraKind.DATA,
    "MetaAppHosting": InfraKind.HOSTING
};


"""Infra the accelerometer server API requires (from api-spec.md)."""
def server_infra_needs(request_id: str) -> list[InfraRequest] {
    return [
        InfraRequest(
            request_id=request_id,
            requested_by="server",
            kind=InfraKind.DATA,
            resource_name="SamplesTable",
            rationale="Persist accelerometer samples for dashboard history",
            spec={
                "engine": "dynamodb",
                "partition_key": "session_id",
                "sort_key": "sample_id",
                "ssm_param": "/wirejac/dev/samples-table-name"
            },
            fulfilled="SamplesTable" in FULFILLED_RESOURCES
        )
    ];
}


"""True when every requested resource is in the fulfilled CDK catalog."""
def infra_catalog_ready(requests: list[InfraRequest]) -> bool {
    for req in requests {
        expected = FULFILLED_RESOURCES.get(req.resource_name);
        if expected is None or expected != req.kind {
            return False;
        }
    }
    return True;
}


"""True when the running server process is wired to the DynamoDB table."""
def samples_table_configured -> bool {
    return bool(os.environ.get("WIREJAC_SAMPLES_TABLE", ""));
}


"""Mark catalog-known requests fulfilled; leave unknown ones pending."""
def resolve_against_catalog(requests: list[InfraRequest]) -> list[InfraRequest] {
    resolved: list[InfraRequest] = [];
    for req in requests {
        known = FULFILLED_RESOURCES.get(req.resource_name);
        resolved.append(InfraRequest(
            request_id=req.request_id,
            requested_by=req.requested_by,
            kind=req.kind,
            resource_name=req.resource_name,
            rationale=req.rationale,
            spec=req.spec,
            fulfilled=known is not None and known == req.kind
        ));
    }
    return resolved;
}


"""Deployment intent for a change that touches server durable storage."""
def intent_for_server_infra(requests: list[InfraRequest]) -> str {
    pending = [r for r in resolve_against_catalog(requests) if not r.fulfilled];
    if pending {
        return "provision_infra";
    }
    # Mock/local runs use the in-memory store; don't force an AWS gate.
    if os.environ.get("WIREJAC_MOCK", "") == "1" {
        return "restart_server";
    }
    if not samples_table_configured() {
        # Constructs exist in CDK but are not deployed / not exported into env.
        return "aws_cdk";
    }
    return "restart_server";
}
