"""Server bridge from the WireJac frontend to the OSP agent graph."""

import from typing { cast }
import from orchestrator.graph {
    ChangeRequest,
    GraphSnapshot,
    ResolveHardwareGate,
    ensure_graph
}
import from orchestrator.adapters { request_events, request_history }
import from orchestrator.hardware_bridge {
    hardware_dispatch_snapshot,
    refresh_hardware_job
}


def:pub ping() -> str {
    return "ok";
}


def _hardware_snapshot(job_id: str) -> dict {
    if not job_id {
        return {};
    }
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
