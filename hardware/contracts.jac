"""Wire contracts shared by the coordinator and hardware service."""

enum ExecutionMode: str {
    PLAN = "plan",
    SIMULATE = "simulate",
    DEPLOY = "deploy"
}

enum ProvisionPolicy: str {
    NEVER = "never",
    ALLOW_IF_NEEDED = "allow_if_needed",
    FORCE = "force"
}

enum JobStatus: str {
    QUEUED = "queued",
    PLANNING = "planning",
    VALIDATING = "validating",
    GENERATING = "generating",
    ASSEMBLY_REQUIRED = "assembly_required",
    SIMULATING = "simulating",
    PROVISIONING = "provisioning",
    DEPLOYING = "deploying",
    VERIFYING = "verifying",
    SUCCEEDED = "succeeded",
    BLOCKED = "blocked",
    FAILED = "failed",
    CANCELLED = "cancelled",
    INTERRUPTED = "interrupted",
    ROLLED_BACK = "rolled_back"
}

enum JobPhase: str {
    INTAKE = "intake",
    PLANNING = "planning",
    VALIDATION = "validation",
    GENERATION = "generation",
    ASSEMBLY = "assembly",
    SIMULATION = "simulation",
    PROVISIONING = "provisioning",
    DEPLOYMENT = "deployment",
    VERIFICATION = "verification",
    COMPLETE = "complete"
}

enum GateKind: str {
    ASSEMBLY_CONFIRMATION = "assembly_confirmation",
    DEVICE_SELECTION = "device_selection",
    DEVICE_PERMISSION = "device_permission",
    MANUAL_VERIFICATION = "manual_verification"
}

enum GateStatus: str {
    OPEN = "open",
    RESOLVED = "resolved",
    REJECTED = "rejected"
}

enum EventKind: str {
    JOB_CREATED = "job_created",
    REVISION_CREATED = "revision_created",
    STATUS_CHANGED = "status_changed",
    PROGRESS = "progress",
    GATE_OPENED = "gate_opened",
    GATE_RESOLVED = "gate_resolved",
    ARTIFACT_READY = "artifact_ready",
    DEVICE_DISCOVERED = "device_discovered",
    LOG = "log",
    WARNING = "warning",
    ERROR = "error",
    COMPLETED = "completed"
}

enum ArtifactKind: str {
    HARDWARE_SPEC = "hardware_spec",
    VISUALIZATION = "visualization",
    ASSEMBLY = "assembly",
    ASSEMBLY_STEP_SVG = "assembly_step_svg",
    WOKWI_DIAGRAM = "wokwi_diagram",
    FIRMWARE_BUNDLE = "firmware_bundle",
    SERIAL_LOG = "serial_log",
    FLASH_BACKUP = "flash_backup",
    SIMULATION_EVIDENCE = "simulation_evidence",
    VERIFICATION_MANIFEST = "verification_manifest",
    OTHER = "other"
}

enum VerificationStatus: str {
    PENDING = "pending",
    PASSED = "passed",
    FAILED = "failed",
    SKIPPED = "skipped",
    USER_ACTION_REQUIRED = "user_action_required"
}

enum IssueSeverity: str {
    INFO = "info",
    WARNING = "warning",
    ERROR = "error",
    FATAL = "fatal"
}

enum PhaseOutcome: str {
    CONTINUE = "continue",
    WAITING = "waiting",
    SKIPPED = "skipped",
    COMPLETE = "complete",
    BLOCKED = "blocked",
    FAILED = "failed"
}

obj IntegrationContract {
    has event_schema_version: str = "1.0",
        backend_endpoint: str = "",
        backend_secret_ref: str = "",
        expected_ack_event: str = "";
}

obj HardwareRequest {
    has project_id: str,
        prompt: str;
    has board_profile: str = "doit-esp32-devkit-v1-30pin",
        allowed_inventory: list[str] = [],
        integration: IntegrationContract | None = None,
        execution_mode: ExecutionMode = ExecutionMode.PLAN,
        device_selector: str = "",
        provision_policy: ProvisionPolicy = ProvisionPolicy.NEVER,
        secret_refs: dict[str, str] = {},
        metadata: dict[str, str] = {};
}

obj ArtifactInput {
    has kind: ArtifactKind,
        name: str,
        uri: str,
        sha256: str;
    has media_type: str = "application/octet-stream",
        size_bytes: int = 0,
        metadata: dict[str, str] = {};
}

obj GateInput {
    has kind: GateKind,
        title: str,
        instructions: str,
        resume_status: JobStatus;
    has metadata: dict[str, str] = {};
}

obj PhaseContext {
    has operation_id: str,
        job_id: str,
        revision_id: str,
        workspace_id: str,
        status: JobStatus,
        request: HardwareRequest;
}

obj PhaseResult {
    has outcome: PhaseOutcome;
    has message: str = "",
        error_code: str = "",
        next_status: JobStatus | None = None,
        artifacts: list[ArtifactInput] = [],
        gate: GateInput | None = None,
        data: dict[str, str] = {};
}

obj JobView {
    has job_id: str,
        project_id: str,
        revision_id: str,
        revision: int,
        prompt: str,
        board_profile: str,
        execution_mode: ExecutionMode,
        status: JobStatus,
        phase: JobPhase,
        progress_percent: int,
        cancel_requested: bool,
        created_at: float,
        updated_at: float,
        error_code: str,
        error_message: str;
}

obj RevisionView {
    has revision_id: str,
        number: int,
        reason: str,
        created_at: float,
        request: HardwareRequest;
}

obj GateView {
    has gate_id: str,
        revision_id: str,
        kind: GateKind,
        status: GateStatus,
        title: str,
        instructions: str,
        resume_status: JobStatus,
        opened_at: float,
        resolved_at: float,
        accepted: bool,
        resolution_note: str,
        metadata: dict[str, str];
}

obj EventView {
    has event_id: str,
        sequence: int,
        kind: EventKind,
        status: JobStatus,
        phase: JobPhase,
        message: str,
        created_at: float,
        data: dict[str, str];
}

obj ArtifactView {
    has artifact_id: str,
        revision_id: str,
        kind: ArtifactKind,
        name: str,
        uri: str,
        sha256: str,
        media_type: str,
        size_bytes: int,
        created_at: float,
        metadata: dict[str, str];
}

obj ArtifactContentView {
    has artifact_id: str,
        name: str,
        media_type: str,
        sha256: str,
        content: bytes;
}

obj CapabilityView {
    has name: str,
        available: bool,
        detail: str;
}

obj VerificationView {
    has verification_id: str,
        status: VerificationStatus,
        summary: str,
        checks: dict[str, str],
        evidence_artifact_ids: list[str],
        created_at: float;
}

obj DeviceView {
    has device_id: str,
        stable_port: str,
        chip_family: str,
        mac_address: str,
        flash_size_bytes: int,
        firmware_kind: str,
        connected: bool,
        last_seen_at: float;
}

obj IssueView {
    has issue_id: str,
        code: str,
        severity: IssueSeverity,
        message: str,
        location: str,
        resolved: bool,
        created_at: float;
}

obj JobDetailView {
    has job: JobView,
        revisions: list[RevisionView],
        gates: list[GateView],
        artifacts: list[ArtifactView],
        events: list[EventView],
        issues: list[IssueView],
        latest_verification: VerificationView | None;
}

obj SubmitJobResponse {
    has job: JobView,
        created: bool,
        idempotent_replay: bool;
}

obj MutationResult {
    has accepted: bool,
        idempotent_replay: bool,
        message: str,
        job: JobView | None;
}
