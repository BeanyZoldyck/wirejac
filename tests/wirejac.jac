"""Tests for the Jac-native WireJac agent graph."""

import os;
import from orchestrator.adapters { deploy }
import from orchestrator.graph {
    ChangeRequest,
    GraphSnapshot,
    ensure_graph,
    validate_plan
}
import from orchestrator.models { ImpactPlan }


test "impact plans require complete routing decisions" {
    valid = ImpactPlan(
        selected=["client"],
        skipped={"server": "unchanged", "device": "unchanged"},
        tasks={"client": "Improve the chart"},
        acceptance=["Chart changed"]
    );
    workspaces = [
        {"name": "client"},
        {"name": "server"},
        {"name": "device"}
    ];
    assert validate_plan(valid, workspaces) == "";

    invalid = ImpactPlan(
        selected=["client"],
        skipped={"server": "unchanged"},
        tasks={"client": "Improve the chart"}
    );
    assert validate_plan(invalid, workspaces) == "Missing skip reason for workspace: device";
}


test "mock request traverses the client-only route" {
    os.environ["WIREJAC_MOCK"] = "1";
    os.environ["WIREJAC_EVENT_FILE"] = "/tmp/wirejac-test-events.jsonl";
    ensure_graph();
    request = ChangeRequest(
        prompt="Make the sample count more prominent",
        request_id="test-client-route"
    );
    root() spawn request;

    assert not request.failed;
    assert request.plan.selected == ["client"];
    assert request.results["client"].success;
    assert request.deployment_result.success;
    assert request.monitor_result.success;
    visited = [event.node_name for event in request.activations];
    assert "client" in visited;
    assert "deployment" in visited;
    assert "monitoring" in visited;
    assert request.plan.skipped["server"] == "No API change";
    assert request.plan.skipped["device"] == "No firmware change";
}


test "device deployment stops at the pipeline placeholder" {
    result = deploy(["device"], "prepare_device");
    assert result.success;
    assert result.awaiting_approval;
    assert result.artifact == "workspace/device/generated/main.py";
}


test "graph snapshot exposes all six nodes" {
    ensure_graph();
    snapshot = GraphSnapshot();
    root() spawn snapshot;
    data = snapshot.reports[0];
    assert data["initialized"];
    assert len(data["nodes"]) == 6;
    assert len(data["edges"]) == 8;
}
