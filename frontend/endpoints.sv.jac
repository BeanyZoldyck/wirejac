"""Server bridge from the Wirejac frontend to the real OSP agent graph."""

import from orchestrator.graph { ChangeRequest, GraphSnapshot, ensure_graph }
import from orchestrator.adapters { request_events, request_history }


def:pub ping() -> str {
    return "ok";
}


def:pub submit_build(prompt: str) -> dict {
    ensure_graph();
    request = ChangeRequest(prompt=prompt);
    root() spawn request;
    return {
        "id": request.request_id,
        "name": prompt,
        "prompt": prompt,
        "status": "failed" if request.failed else "done",
        "events": request_events(request.request_id)
    };
}


def:pub get_request_events(request_id: str) -> list[dict] {
    return request_events(request_id);
}


def:pub get_request_history() -> list[dict] {
    return request_history();
}


def:pub get_graph_snapshot() -> dict {
    ensure_graph();
    snapshot = GraphSnapshot();
    root() spawn snapshot;
    if snapshot.reports {
        return snapshot.reports[0];
    }
    return {"initialized": False, "nodes": [], "edges": []};
}
