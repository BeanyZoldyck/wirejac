"""Wirejac AWS backend contracts.

Neutral data shapes shared between the backend worker, the infrastructure
worker, and the deployment pipeline.

This module deliberately contains no graph vocabulary -- no node, edge, walker,
or ActivationState. That keeps it valid regardless of how the core orchestrator
scaffold defines its archetypes, and lets the node abilities that eventually
call into here own the mapping from StepStatus to ActivationState.
"""

enum StepName {
    BUILD = "cdk_build",
    TEST = "cdk_test",
    SYNTH = "cdk_synth",
    POLICY = "policy_validation",
    DIFF = "cdk_diff",
    APPROVAL = "human_approval",
    DEPLOY = "cdk_deploy",
    HEALTH = "health_check"
}

enum StepStatus {
    PASSED = "passed",
    FAILED = "failed",
    SKIPPED = "skipped",
    AWAITING_APPROVAL = "awaiting_approval"
}

enum InfraKind {
    RUNTIME = "backend_runtime",
    DATA = "data",
    HOSTING = "frontend_hosting",
    OBSERVABILITY = "observability"
}

obj StepResult {
    has step: StepName,
        status: StepStatus,
        summary: str = "",
        output_ref: str = "",
        error: str = "",
        duration_ms: int = 0;

    def passed -> bool {
        return self.status == StepStatus.PASSED;
    }
}

obj DeployTarget {
    """Everything the deployment node is allowed to persist.

    No passwords, access keys, secret keys, or session tokens. Only the
    *name* of an AWS profile is stored; credential resolution happens
    outside the project, in the local AWS config or the process environment.
    """

    has stack_name: str = "WirejacDevStack",
        account_id: str = "",
        region: str = "us-west-2",
        profile: str = "",
        app_dir: str = "infrastructure",
        last_deployment_id: str = "",
        last_deployment_status: str = "",
        change_summary: str = "";

    """Profile flag for the CDK CLI, or nothing when using env credentials."""
    def cli_env_flags -> list[str] {
        return ["--profile", self.profile] if self.profile else [];
    }
}

obj InfraRequest {
    """Emitted by the backend worker; fulfilled by the infrastructure worker.

    The backend worker does not write CDK code. It describes what it needs
    and the infrastructure worker owns the constructs.
    """

    has request_id: str,
        requested_by: str,
        kind: InfraKind,
        resource_name: str,
        rationale: str = "",
        spec: dict[str, str] = {},
        fulfilled: bool = False;
}

obj PipelineResult {
    has target: DeployTarget,
        steps: list[StepResult] = [],
        success: bool = False,
        awaiting_approval: bool = False,
        halted_at: str = "";

    def record(result: StepResult) {
        self.steps.append(result);
    }

    def failed_step -> StepResult | None {
        for step in self.steps {
            if step.status == StepStatus.FAILED {
                return step;
            }
        }
        return None;
    }
}
