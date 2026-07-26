"""Typed values carried through the WireJac agent graph."""

enum ActivationState {
    PLANNED = "planned",
    QUEUED = "queued",
    RUNNING = "running",
    REPAIRING = "repairing",
    REPLANNING = "replanning",
    AWAITING_APPROVAL = "awaiting_approval",
    VALIDATING = "validating",
    DEPLOYING = "deploying",
    MONITORING = "monitoring",
    SKIPPED = "skipped",
    SUCCEEDED = "succeeded",
    FAILED = "failed",
    CANCELLED = "cancelled"
}

enum WorkspaceKind {
    CLIENT = "client",
    SERVER = "server",
    DEVICE = "device"
}

obj Activation {
    has request_id: str,
        node_name: str,
        state: ActivationState,
        summary: str = "",
        timestamp: str = "",
        tool_count: int = 0,
        revision: str = "",
        error: str = "";
}

obj ImpactPlan {
    has selected: list[str] = [],
        skipped: dict[str, str] = {},
        tasks: dict[str, str] = {},
        acceptance: list[str] = [],
        contract_change_expected: bool = False,
        deployment_intent: str = "hot_reload";
}

obj AgentResult {
    has success: bool = False,
        summary: str = "",
        tool_count: int = 0,
        revision: str = "",
        contract_changed: bool = False,
        error: str = "";
}

obj DeploymentResult {
    has success: bool = False,
        summary: str = "",
        awaiting_approval: bool = False,
        artifact: str = "",
        error: str = "";
}

obj MonitorResult {
    has success: bool = False,
        summary: str = "",
        errors: list[str] = [];
}
