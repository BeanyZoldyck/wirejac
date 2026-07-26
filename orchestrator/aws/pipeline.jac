"""The eight-step Wirejac CDK deployment pipeline.

    1. cdk build
    2. cdk tests
    3. cdk synth
    4. policy / resource validation
    5. cdk diff
    6. human approval
    7. cdk deploy
    8. post-deployment health check

Steps 1-5 mutate nothing, so `run_validation` is safe to call repeatedly and
safe to run in a bounded repair loop. Step 6 is a hard gate. Steps 7-8 are the
only mutating steps and require an `ApprovalGrant` bound to the exact change
that was reviewed.

These are plain functions, not node abilities. Whatever graph node eventually
owns deployment calls them in order and maps `StepStatus` onto its own
activation vocabulary. That keeps this module independent of the orchestrator
scaffold.
"""

import re;
import time;
import hashlib;
import subprocess;
import os;

import from orchestrator.aws.contracts {
    StepName,
    StepStatus,
    StepResult,
    DeployTarget,
    PipelineResult
}
import from orchestrator.aws.redact { redact }
import from orchestrator.aws.policy { validate_policy }

# Only these executables may ever be invoked. The command list is built here,
# never supplied by a model.
glob ALLOWED_EXECUTABLES: list[str] = ["npm", "npx", "aws"];

glob LOG_DIR: str = "runtime/logs";

glob DEFAULT_TIMEOUT: int = 300;
glob DEPLOY_TIMEOUT: int = 1800;


obj CommandOutput {
    has exit_code: int = 0,
        text: str = "",
        timed_out: bool = False;
}


"""A human approval bound to one request and one reviewed change.

`change_hash` is the hash of the redacted diff the human actually saw. If the
diff changes after approval, the grant no longer verifies and the deploy is
refused. Approval is never a standing permission.
"""
obj ApprovalGrant {
    has request_id: str,
        change_hash: str,
        approved_by: str,
        granted_at: str = "";
}


"""Stable hash of a change summary, used to bind an approval to a diff."""
def change_hash(summary: str) -> str {
    return hashlib.sha256(summary.encode("utf-8")).hexdigest()[:16];
}


"""True only when the grant matches this request and this exact change."""
def verify_approval(
    grant: ApprovalGrant | None,
    request_id: str,
    summary: str
) -> bool {
    if grant is None {
        return False;
    }
    if grant.request_id != request_id {
        return False;
    }
    return grant.change_hash == change_hash(summary);
}


"""Write redacted output to a log file and return a reference to it.

Long command output is referenced, not embedded in events.
"""
def store_output(request_id: str, step: StepName, text: str) -> str {
    safe_id = re.sub(r"[^A-Za-z0-9._-]", "_", request_id) if request_id else "adhoc";
    directory = os.path.join(LOG_DIR, safe_id);
    os.makedirs(directory, exist_ok=True);
    path = os.path.join(directory, f"{step.value}.log");
    handle = open(path, "w");
    handle.write(redact(text, max_chars=200000));
    handle.close();
    return path;
}


"""Run an allowlisted command with no shell, bounded time, and merged output."""
def exec_command(
    argv: list[str],
    cwd: str,
    timeout: int = DEFAULT_TIMEOUT
) -> CommandOutput {
    if not argv {
        return CommandOutput(exit_code=126, text="empty command");
    }
    if argv[0] not in ALLOWED_EXECUTABLES {
        return CommandOutput(
            exit_code=126,
            text=f"executable '{argv[0]}' is not allowlisted"
        );
    }
    try {
        completed = subprocess.run(
            argv,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=False
        );
        merged = (completed.stdout or "") + (completed.stderr or "");
        return CommandOutput(exit_code=completed.returncode, text=merged);
    } except subprocess.TimeoutExpired {
        return CommandOutput(
            exit_code=124,
            text=f"command timed out after {timeout}s",
            timed_out=True
        );
    } except Exception as err {
        return CommandOutput(exit_code=125, text=f"{type(err).__name__}: {err}");
    }
}


"""Run one pipeline step and package the outcome as a StepResult."""
def run_step(
    step: StepName,
    argv: list[str],
    target: DeployTarget,
    request_id: str = "",
    timeout: int = DEFAULT_TIMEOUT
) -> StepResult {
    started = time.time();
    output = exec_command(argv, target.app_dir, timeout);
    elapsed = int((time.time() - started) * 1000);
    reference = store_output(request_id, step, output.text);
    if output.exit_code == 0 {
        return StepResult(
            step=step,
            status=StepStatus.PASSED,
            summary=f"{step.value} passed",
            output_ref=reference,
            duration_ms=elapsed
        );
    }
    return StepResult(
        step=step,
        status=StepStatus.FAILED,
        summary=f"{step.value} failed with exit code {output.exit_code}",
        output_ref=reference,
        error=redact(output.text, max_chars=1200),
        duration_ms=elapsed
    );
}


"""Step 1: compile the CDK TypeScript app."""
def cdk_build(target: DeployTarget, request_id: str = "") -> StepResult {
    return run_step(StepName.BUILD, ["npm", "run", "build"], target, request_id);
}


"""Step 2: run the CDK construct assertion tests."""
def cdk_test(target: DeployTarget, request_id: str = "") -> StepResult {
    return run_step(StepName.TEST, ["npx", "jest"], target, request_id);
}


"""Step 3: synthesize CloudFormation templates."""
def cdk_synth(target: DeployTarget, request_id: str = "") -> StepResult {
    argv = ["npx", "cdk", "synth", target.stack_name, "--quiet"]
        + target.cli_env_flags();
    return run_step(StepName.SYNTH, argv, target, request_id);
}


"""Step 5: compute the pending change set against the deployed stack.

`cdk diff` exits non-zero when differences exist, which is not a failure here,
so the exit code is interpreted rather than passed straight through.
"""
def cdk_diff(target: DeployTarget, request_id: str = "") -> StepResult {
    argv = ["npx", "cdk", "diff", target.stack_name] + target.cli_env_flags();
    started = time.time();
    output = exec_command(argv, target.app_dir, DEFAULT_TIMEOUT);
    elapsed = int((time.time() - started) * 1000);
    reference = store_output(request_id, StepName.DIFF, output.text);
    if output.timed_out or output.exit_code > 1 {
        return StepResult(
            step=StepName.DIFF,
            status=StepStatus.FAILED,
            summary="cdk diff could not be computed",
            output_ref=reference,
            error=redact(output.text, max_chars=1200),
            duration_ms=elapsed
        );
    }
    summary = redact(output.text, max_chars=4000);
    target.change_summary = summary;
    return StepResult(
        step=StepName.DIFF,
        status=StepStatus.PASSED,
        summary=summary,
        output_ref=reference,
        duration_ms=elapsed
    );
}


"""Step 6: pause for human approval. Never self-approves."""
def request_approval(target: DeployTarget) -> StepResult {
    return StepResult(
        step=StepName.APPROVAL,
        status=StepStatus.AWAITING_APPROVAL,
        summary=(
            f"Awaiting approval to deploy {target.stack_name} "
            f"to {target.region} (change {change_hash(target.change_summary)})"
        )
    );
}


"""Step 7: deploy. Refuses without a grant matching the reviewed diff.

`--require-approval never` is correct here precisely because approval already
happened at step 6; without it the CDK CLI blocks on an interactive prompt.
"""
def cdk_deploy(
    target: DeployTarget,
    grant: ApprovalGrant | None,
    request_id: str = ""
) -> StepResult {
    if not verify_approval(grant, request_id, target.change_summary) {
        return StepResult(
            step=StepName.DEPLOY,
            status=StepStatus.FAILED,
            summary="Deployment refused: no valid approval for this change",
            error="approval missing, for another request, or diff changed since review"
        );
    }
    argv = [
        "npx", "cdk", "deploy", target.stack_name,
        "--require-approval", "never",
        "--progress", "events",
        "--ci"
    ] + target.cli_env_flags();
    result = run_step(
        StepName.DEPLOY, argv, target, request_id, DEPLOY_TIMEOUT
    );
    target.last_deployment_id = request_id;
    target.last_deployment_status = result.status.value;
    return result;
}


"""Step 8: confirm the stack settled into a healthy terminal state."""
def health_check(target: DeployTarget, request_id: str = "") -> StepResult {
    argv = [
        "aws", "cloudformation", "describe-stacks",
        "--stack-name", target.stack_name,
        "--region", target.region,
        "--query", "Stacks[0].StackStatus",
        "--output", "text"
    ] + target.cli_env_flags();
    started = time.time();
    output = exec_command(argv, target.app_dir, DEFAULT_TIMEOUT);
    elapsed = int((time.time() - started) * 1000);
    reference = store_output(request_id, StepName.HEALTH, output.text);
    status = output.text.strip();
    healthy = status in ["CREATE_COMPLETE", "UPDATE_COMPLETE"];
    if output.exit_code == 0 and healthy {
        return StepResult(
            step=StepName.HEALTH,
            status=StepStatus.PASSED,
            summary=f"{target.stack_name} is {status}",
            output_ref=reference,
            duration_ms=elapsed
        );
    }
    return StepResult(
        step=StepName.HEALTH,
        status=StepStatus.FAILED,
        summary=f"{target.stack_name} is not healthy",
        output_ref=reference,
        error=redact(output.text, max_chars=600),
        duration_ms=elapsed
    );
}


"""Steps 1-5 plus the approval gate. Mutates no AWS resources.

Halts at the first failing step so a repair loop gets one clear cause.
"""
def run_validation(
    target: DeployTarget,
    request_id: str = "",
    policy_check: bool = True
) -> PipelineResult {
    result = PipelineResult(target=target);
    steps = [
        cdk_build(target, request_id),
        cdk_test(target, request_id),
        cdk_synth(target, request_id)
    ];
    for step in steps {
        result.record(step);
        if not step.passed() {
            result.halted_at = step.step.value;
            return result;
        }
    }

    policy = validate_policy(target) if policy_check else StepResult(
        step=StepName.POLICY,
        status=StepStatus.SKIPPED,
        summary="policy validation disabled"
    );
    result.record(policy);
    if policy.status == StepStatus.FAILED {
        result.halted_at = StepName.POLICY.value;
        return result;
    }

    diff = cdk_diff(target, request_id);
    result.record(diff);
    if not diff.passed() {
        result.halted_at = StepName.DIFF.value;
        return result;
    }

    approval = request_approval(target);
    result.record(approval);
    result.awaiting_approval = True;
    result.halted_at = StepName.APPROVAL.value;
    return result;
}


"""Steps 7-8. Only reachable with a grant bound to the reviewed diff."""
def run_deployment(
    target: DeployTarget,
    grant: ApprovalGrant | None,
    request_id: str = ""
) -> PipelineResult {
    result = PipelineResult(target=target);
    deploy = cdk_deploy(target, grant, request_id);
    result.record(deploy);
    if not deploy.passed() {
        result.halted_at = StepName.DEPLOY.value;
        return result;
    }
    health = health_check(target, request_id);
    result.record(health);
    if not health.passed() {
        result.halted_at = StepName.HEALTH.value;
        return result;
    }
    result.success = True;
    return result;
}
