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


with entry {
    ensure_graph();
    integration._register_hardware_service();
    prompt = os.environ.get("WIREJAC_PROMPT", "");
    if prompt {
        root spawn ChangeRequest(prompt=prompt);
    } else {
        print(
            "WireJac graph and hardware service initialized. Set "
            "WIREJAC_PROMPT to run a change request."
        );
    }
}
