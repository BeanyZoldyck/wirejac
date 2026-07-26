"""Bridge between the AWS CDK pipeline and the WireJac graph's Deployment node.

The graph's Deployment node calls `deploy(selected, intent) -> DeploymentResult`.
This module supplies an AWS-backed implementation of that contract while keeping
all CDK mechanics in `orchestrator/aws/`.

The two-phase shape matters. `deploy_aws` with no grant runs only the
non-mutating validation steps and returns `awaiting_approval=True` carrying the
change hash as the artifact. Nothing is deployed until it is called again with an
`ApprovalGrant` matching that exact hash, which is the same artifact-bound
approval rule the device flash gate uses.
"""

import os;

import from orchestrator.models { DeploymentResult }
import from orchestrator.aws.contracts { DeployTarget, StepResult }
import from orchestrator.aws.pipeline {
    run_validation,
    run_deployment,
    change_hash,
    ApprovalGrant
}

# Deployment intents this module handles. Anything else falls through to the
# scaffold's own deterministic adapters.
glob AWS_INTENTS: list[str] = ["aws_cdk", "deploy_backend", "provision_infra"];


"""True when this intent should be handled by the CDK pipeline."""
def is_aws_intent(intent: str) -> bool {
    return intent in AWS_INTENTS;
}


"""Build a deploy target from the environment.

Only the profile *name* is read. Credentials themselves are resolved by the AWS
SDK from the local config or process environment and never enter graph state.
"""
def aws_target -> DeployTarget {
    return DeployTarget(
        stack_name=os.environ.get("WIREJAC_STACK", "WirejacDevStack"),
        region=os.environ.get("WIREJAC_REGION", "us-west-2"),
        profile=os.environ.get("WIREJAC_AWS_PROFILE", ""),
        app_dir=os.environ.get("WIREJAC_CDK_DIR", "infrastructure")
    );
}


"""Render pipeline step outcomes as one compact, dashboard-safe line."""
def summarize(steps: list[StepResult]) -> str {
    parts: list[str] = [];
    for step in steps {
        parts.append(f"{step.step.value}={step.status.value}");
    }
    return ", ".join(parts);
}


"""Phase one: validate. Never mutates AWS, never deploys.

Returns `awaiting_approval=True` with the change hash as the artifact when the
stack is ready to deploy.
"""
def validate_aws(request_id: str) -> DeploymentResult {
    target = aws_target();
    result = run_validation(target, request_id=request_id);
    trace = summarize(result.steps);

    if result.awaiting_approval {
        return DeploymentResult(
            success=True,
            awaiting_approval=True,
            summary=(
                f"{target.stack_name} validated in {target.region}; "
                f"awaiting approval ({trace})"
            ),
            artifact=change_hash(target.change_summary)
        );
    }

    failed = result.failed_step();
    return DeploymentResult(
        success=False,
        awaiting_approval=False,
        summary=f"CDK validation halted at {result.halted_at} ({trace})",
        error=failed.error if failed else "validation did not reach the approval gate"
    );
}


"""Phase two: deploy. Requires a grant bound to the validated change."""
def deploy_aws(request_id: str, grant: ApprovalGrant | None) -> DeploymentResult {
    if grant is None {
        return validate_aws(request_id);
    }

    target = aws_target();
    # Re-derive the diff so the grant is checked against current reality rather
    # than a summary cached from an earlier walk.
    validation = run_validation(target, request_id=request_id);
    if not validation.awaiting_approval {
        failed = validation.failed_step();
        return DeploymentResult(
            success=False,
            summary=f"Re-validation failed before deploy at {validation.halted_at}",
            error=failed.error if failed else "stack no longer passes validation"
        );
    }

    result = run_deployment(target, grant, request_id=request_id);
    trace = summarize(result.steps);
    if result.success {
        return DeploymentResult(
            success=True,
            summary=f"{target.stack_name} deployed to {target.region} ({trace})",
            artifact=target.last_deployment_id
        );
    }

    failed = result.failed_step();
    return DeploymentResult(
        success=False,
        summary=f"CDK deployment halted at {result.halted_at} ({trace})",
        error=failed.error if failed else "deployment did not complete"
    );
}
