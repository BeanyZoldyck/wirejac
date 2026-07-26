"""WireJac agent graph and guarded hardware-service entry point."""

import os;
include hardware.api;
import hardware.integration as integration;
import from orchestrator.graph {
    ChangeRequest,
    GraphSnapshot,
    SubmitChange,
    ensure_graph
}
import from orchestrator.adapters { request_events, request_history }


def:pub get_request_events(request_id: str) -> list[dict] {
    return request_events(request_id);
}


def:pub get_request_history() -> list[dict] {
    return request_history();
}


with entry {
    ensure_graph();
    integration._register_hardware_service();
    prompt = os.environ.get("WIREJAC_PROMPT", "");
    if prompt {
        root() spawn ChangeRequest(prompt=prompt);
    } else {
        print(
            "WireJac graph and hardware service initialized. Set "
            "WIREJAC_PROMPT to run a change request."
        );
    }
}
