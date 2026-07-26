"""Manual driver for the AWS deployment bridge.

Exercises the same `DeploymentResult` contract the graph's Deployment node uses,
without spawning a walker.

    jac run orchestrator/aws/validate_run.jac

Phase one runs steps 1-5 and stops at the approval gate. Phase two is then
attempted twice: once with a deliberately wrong grant, which must be refused,
and once with a grant bound to the real change hash. Set WIREJAC_CONFIRM_DEPLOY=1
to let the second attempt actually reach `cdk deploy`; by default it is skipped
so this driver mutates nothing.
"""

import os;

import from orchestrator.aws.contracts { StepStatus }
import from orchestrator.aws.pipeline { ApprovalGrant }
import from orchestrator.aws.bridge {
    aws_target,
    validate_aws,
    deploy_aws,
    is_aws_intent
}


with entry {
    target = aws_target();
    print(f"stack   : {target.stack_name} ({target.region})");
    print(f"profile : {target.profile or '<environment credentials>'}");
    print(f"aws intent recognized: {is_aws_intent('aws_cdk')}");
    print("");

    print("-- phase one: validation --");
    validated = validate_aws("local-validate");
    print(f"  success          : {validated.success}");
    print(f"  awaiting approval: {validated.awaiting_approval}");
    print(f"  summary          : {validated.summary}");
    print(f"  change hash      : {validated.artifact}");
    if validated.error {
        print(f"  error            : {validated.error[:400]}");
    }
    print("");

    if not validated.awaiting_approval {
        print("validation did not reach the approval gate; stopping");
    } else {
        print("-- phase two: deploy with a stale grant (must be refused) --");
        stale = ApprovalGrant(
            request_id="local-validate",
            change_hash="0000000000000000",
            approved_by="test"
        );
        refused = deploy_aws("local-validate", stale);
        print(f"  success: {refused.success}");
        print(f"  summary: {refused.summary}");
        print("");

        print("-- phase two: deploy with a valid grant --");
        if os.environ.get("WIREJAC_CONFIRM_DEPLOY", "") != "1" {
            print("  skipped (set WIREJAC_CONFIRM_DEPLOY=1 to really deploy)");
        } else {
            grant = ApprovalGrant(
                request_id="local-validate",
                change_hash=validated.artifact,
                approved_by="operator"
            );
            deployed = deploy_aws("local-validate", grant);
            print(f"  success: {deployed.success}");
            print(f"  summary: {deployed.summary}");
            if deployed.error {
                print(f"  error  : {deployed.error[:400]}");
            }
        }
    }
}
