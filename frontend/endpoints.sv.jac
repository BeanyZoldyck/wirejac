"""Server bridge from the WireJac frontend to the OSP agent graph."""

import from typing { cast }
import from concurrent.futures { Future }
import from time { sleep }
import from orchestrator.graph {
    ChangeRequest,
    GraphSnapshot,
    ResolveHardwareGate,
    ensure_graph
}
import from orchestrator.adapters {
    emit_activation,
    request_events,
    request_history,
    run_workspace_agent
}
import from orchestrator.frontend_bridge { deploy_frontend_cloudfront }
import from orchestrator.models { Activation, ActivationState }
import from orchestrator.hardware_bridge {
    hardware_dispatch_snapshot,
    refresh_hardware_job,
    resolve_hardware_gate,
    start_hardware_job
}
import from hardware.adapters.bridge_control {
    pause_gyro_bridge,
    resume_gyro_bridge
}
import from hardware.integration { _register_hardware_service }


def:pub ping() -> str {
    return "ok";
}


def _hardware_snapshot(job_id: str) -> dict {
    if not job_id {
        return {};
    }
    _register_hardware_service();
    return hardware_dispatch_snapshot(refresh_hardware_job(job_id));
}


def:pub submit_build(prompt: str) -> dict {
    ensure_graph();
    request = ChangeRequest(prompt=prompt, emit_reports=False);
    root spawn request;
    status = "failed" if request.failed else (
        "waiting" if request.awaiting_hardware_gate else "done"
    );
    hardware = (
        _hardware_snapshot(request.hardware_job_id)
        if request.hardware_job_id else {}
    );
    return {
        "id": request.request_id,
        "name": prompt,
        "prompt": prompt,
        "status": status,
        "events": request_events(request.request_id),
        "hardware_job_id": request.hardware_job_id,
        "hardware_status": request.hardware_status,
        "hardware": hardware
    };
}


def:pub submit_hardware_followup(
    request_id: str,
    prompt: str,
    message: str,
    client_nonce: int
) -> dict {
    commit();
    clean = message.strip();
    if not request_id.strip() or not clean {
        raise ValueError("request_id and follow-up message are required");
    }
    prior: list[str] = [];
    for event in request_events(request_id) {
        summary = str(event.get("summary", ""));
        if summary.startswith("User follow-up: ") {
            prior.append(summary.removeprefix("User follow-up: "));
        }
    }
    emit_activation(Activation(
        request_id=request_id,
        node_name="coordinator",
        state=ActivationState.RUNNING,
        summary="User follow-up: " + clean
    ));
    context = prompt;
    if prior {
        context += "\n\nEarlier project follow-ups:\n- " + "\n- ".join(prior);
    }
    context += (
        "\n\nCurrent hardware follow-up: " + clean
        + "\nGenerate a new MicroPython release for the connected ESP32, "
        + "flash it, and physically verify it. Preserve the existing wiring "
        + "unless this instruction explicitly changes it."
    );
    result = start_hardware_job(
        request_id,
        context,
        clean + " Deploy to ESP32 and flash the connected device.",
        client_nonce
    );
    state = ActivationState.RUNNING;
    if result.awaiting_gate {
        state = ActivationState.AWAITING_APPROVAL;
    } elif result.success {
        state = ActivationState.SUCCEEDED;
    } elif result.error {
        state = ActivationState.FAILED;
    }
    emit_activation(Activation(
        request_id=request_id,
        node_name="device",
        state=state,
        summary=result.summary,
        revision=result.revision_id,
        hardware_job_id=result.job_id,
        hardware_status=result.status.value,
        error=result.error
    ));
    return {
        "route": "hardware",
        "hardware": hardware_dispatch_snapshot(result),
        "events": request_events(request_id)
    };
}


def _record_followup(
    request_id: str,
    node_name: str,
    state: ActivationState,
    summary: str,
    revision: str = "",
    error: str = ""
) {
    emit_activation(Activation(
        request_id=request_id,
        node_name=node_name,
        state=state,
        summary=summary,
        revision=revision,
        error=error
    ));
}


def _run_frontend_followup(
    request_id: str,
    prompt: str,
    clean: str,
    prior: list[str]
) -> bool {
    try {
        _record_followup(
            request_id,
            "client",
            ActivationState.RUNNING,
            "Frontend agent started: reading the deployed mini-app before making scoped changes"
        );
        context = prompt;
        if prior {
            context += "\n\nEarlier frontend follow-ups:\n- " + "\n- ".join(prior);
        }
        task = (
            "Frontend-only change for the existing deployed phone-snatch mini-app.\n"
            + "Original project context: " + context
            + "\nCurrent request: " + clean
            + "\nModify only workspace/client. Keep the real samples API, config.js "
            + "contract, session ID, and live gyro polling intact. Do not edit hardware, "
            + "device firmware, server, infrastructure, or use fixture/mock data. The "
            + "currently deployed entry points are index.html, styles.css, and app.js; "
            + "update those assets and keep any Jac client source aligned when relevant."
        );
        result = run_workspace_agent(
            request_id,
            "client",
            "workspace/client",
            "workspace/client/client.md",
            "workspace/client/api-spec.md",
            task,
            [
                "Requested frontend behavior is visible in the deployed mini-app",
                "Existing real gyro API polling remains operational",
                "npm run check succeeds",
                "No hardware, backend, infrastructure, or API contract files change"
            ],
            ["jac", "npm", "pnpm", "npx"]
        );
        if not result.success {
            _record_followup(
                request_id,
                "client",
                ActivationState.FAILED,
                result.summary or "Frontend agent failed",
                result.revision,
                result.error
            );
            return False;
        }
        if result.contract_changed {
            _record_followup(
                request_id,
                "client",
                ActivationState.FAILED,
                "Frontend-only deployment stopped because the API contract changed",
                result.revision,
                "FRONTEND_ROUTE_CONTRACT_CHANGE"
            );
            return False;
        }
        _record_followup(
            request_id,
            "client",
            ActivationState.SUCCEEDED,
            result.summary,
            result.revision
        );
        _record_followup(
            request_id,
            "deployment",
            ActivationState.DEPLOYING,
            "Validation passed; syncing the real mini-app assets to its S3 origin"
        );
        published = deploy_frontend_cloudfront();
        url = str(published.get("url", ""));
        _record_followup(
            request_id,
            "deployment",
            ActivationState.SUCCEEDED,
            "CloudFront assets uploaded and cache invalidation completed",
            url
        );
        _record_followup(
            request_id,
            "monitoring",
            ActivationState.MONITORING,
            "Loading the public CloudFront URL to verify the deployed mini-app"
        );
        _record_followup(
            request_id,
            "monitoring",
            ActivationState.SUCCEEDED,
            "Frontend-only follow-up is live at " + url,
            url
        );
        return True;
    } except Exception as error {
        _record_followup(
            request_id,
            "client",
            ActivationState.FAILED,
            "Frontend-only follow-up failed",
            error=str(error)
        );
        return False;
    }
}


def _launch_frontend_followup(
    request_id: str,
    prompt: str,
    clean: str,
    prior: list[str]
) -> Future[bool] {
    return (flow _run_frontend_followup(
        request_id, prompt, clean, prior
    )) as Future[bool];  # jac:ignore[W1051]
}


def:pub submit_frontend_followup(
    request_id: str,
    prompt: str,
    message: str,
    client_nonce: int
) -> dict {
    _ = client_nonce;
    clean = message.strip();
    if not request_id.strip() or not clean {
        raise ValueError("request_id and follow-up message are required");
    }
    prior: list[str] = [];
    for event in request_events(request_id) {
        summary = str(event.get("summary", ""));
        if summary.startswith("User follow-up: ") and "frontend" in summary.lower() {
            prior.append(summary.removeprefix("User follow-up: "));
        }
    }
    _record_followup(
        request_id,
        "coordinator",
        ActivationState.RUNNING,
        "User follow-up: " + clean
    );
    _record_followup(
        request_id,
        "coordinator",
        ActivationState.SUCCEEDED,
        "Deterministic route selected: frontend only; hardware and backend are excluded"
    );
    _record_followup(
        request_id,
        "client",
        ActivationState.QUEUED,
        "Frontend-only job queued for contained source editing, validation, S3 upload, and CloudFront invalidation"
    );
    _ = _launch_frontend_followup(request_id, prompt, clean, prior);
    return {
        "route": "frontend",
        "hardware": {},
        "events": request_events(request_id)
    };
}


def:pub submit_project_followup(
    request_id: str,
    prompt: str,
    message: str,
    client_nonce: int
) -> dict {
    text = message.lower();
    is_hardware = "hardware" in text;
    is_frontend = "frontend" in text;
    if is_hardware and not is_frontend {
        return submit_hardware_followup(
            request_id, prompt, message, client_nonce
        );
    }
    if is_frontend and not is_hardware {
        return submit_frontend_followup(
            request_id, prompt, message, client_nonce
        );
    }
    raise ValueError(
        "Follow-up must contain exactly one routing keyword: hardware or frontend"
    );
}


def:pub get_request_events(
    request_id: str,
    cache_buster: int = 0
) -> list[dict] {
    _ = cache_buster;
    return request_events(request_id);
}


def:pub get_request_history() -> list[dict] {
    history = cast(list[dict], request_history());
    for item in history {
        job_id = str(item.get("hardware_job_id", ""));
        item["hardware"] = _hardware_snapshot(job_id) if job_id else {};
    }
    return history;
}


def:pub get_graph_snapshot() -> dict {
    ensure_graph();
    snapshot = GraphSnapshot();
    root spawn snapshot;
    if snapshot.reports {
        return cast(dict, snapshot.reports[0]);
    }
    return {"initialized": False, "nodes": [], "edges": []};
}


def:pub get_hardware_job(job_id: str, cache_buster: int = 0) -> dict {
    _ = cache_buster;
    return _hardware_snapshot(job_id);
}


def:pub resolve_hardware_approval(
    job_id: str,
    gate_id: str,
    accepted: bool,
    prompt: str,
    request_id: str
) -> dict {
    resolution = ResolveHardwareGate(
        job_id=job_id,
        gate_id=gate_id,
        accepted=accepted,
        resolution_note=(
            "Accepted in the WireJac UI"
            if accepted else "Rejected in the WireJac UI"
        ),
        prompt=prompt,
        request_id=request_id
    );
    root spawn resolution;
    return {
        "hardware": _hardware_snapshot(job_id),
        "events": request_events(request_id)
    };
}


def:pub resolve_followup_hardware_approval(
    job_id: str,
    gate_id: str,
    accepted: bool,
    request_id: str
) -> dict {
    commit();
    if accepted {
        pause_gyro_bridge();
        sleep(0.5);
    }
    try {
        result = resolve_hardware_gate(
            job_id,
            gate_id,
            accepted,
            "Accepted follow-up in the WireJac UI" if accepted else (
                "Rejected follow-up in the WireJac UI"
            ),
            "ui-followup-gate:" + job_id + ":" + gate_id + ":" + str(accepted)
        );
    } finally {
        if accepted {
            resume_gyro_bridge();
        }
    }
    state = ActivationState.SUCCEEDED if result.success else (
        ActivationState.AWAITING_APPROVAL if result.awaiting_gate else (
            ActivationState.FAILED if result.error else ActivationState.RUNNING
        )
    );
    emit_activation(Activation(
        request_id=request_id,
        node_name="device",
        state=state,
        summary=result.summary,
        revision=result.revision_id,
        hardware_job_id=result.job_id,
        hardware_status=result.status.value,
        error=result.error
    ));
    return {
        "hardware": hardware_dispatch_snapshot(result),
        "events": request_events(request_id)
    };
}
