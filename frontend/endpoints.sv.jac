"""Server-side HTTP bridge to the Wirejac orchestration service."""

import os;
import from typing { cast }

::py::
import json
import os
import urllib.error
import urllib.request


def _orchestrator_call(path, payload):
    base = os.environ.get("WIREJAC_ORCHESTRATOR_URL", "http://127.0.0.1:8000").rstrip("/")
    request = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:2000]
        raise RuntimeError(f"orchestrator HTTP {exc.code}: {detail}") from exc
    if not body.get("ok"):
        raise RuntimeError(str(body.get("error") or "orchestrator request failed"))
    return body.get("data", {})


def _submit_build(prompt):
    data = _orchestrator_call("/walker/SubmitChange", {"prompt": prompt})
    reports = data.get("reports") or []
    events = reports[0] if reports else []
    request_id = events[0].get("request_id", "") if events else ""
    failed = any(event.get("state") == "failed" for event in events)
    return {
        "id": request_id,
        "name": prompt,
        "prompt": prompt,
        "status": "failed" if failed else "done",
        "events": events,
    }


def _function_result(name, payload):
    data = _orchestrator_call(f"/function/{name}", payload)
    return data.get("result", data)
::py::


def:pub ping() -> str {
    return "ok";
}


def:pub submit_build(prompt: str) -> dict {
    return cast(dict, _submit_build(prompt));
}


def:pub get_request_events(request_id: str) -> list[dict] {
    return cast(list[dict], _function_result(
        "get_request_events", {"request_id": request_id}
    ));
}


def:pub get_request_history() -> list[dict] {
    return cast(list[dict], _function_result("get_request_history", {}));
}


def:pub get_graph_snapshot() -> dict {
    data = cast(dict, _orchestrator_call("/walker/GraphSnapshot", {}));
    reports = cast(list, data.get("reports", []));
    if reports {
        return cast(dict, reports[0]);
    }
    return {"initialized": False, "nodes": [], "edges": []};
}
