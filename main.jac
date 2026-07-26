"""WireJac agent graph entry point."""

import os;
import from orchestrator.graph {
    ChangeRequest,
    GraphSnapshot,
    SubmitChange,
    ensure_graph
}


with entry {
    ensure_graph();
    prompt = os.environ.get("WIREJAC_PROMPT", "");
    if prompt {
        root() spawn ChangeRequest(prompt=prompt);
    } else {
        print(
            "WireJac graph initialized. Set WIREJAC_PROMPT to run a change "
            "or use the ChangeRequest walker endpoint with jac start."
        );
    }
}
