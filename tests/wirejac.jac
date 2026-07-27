"""Tests for the Jac-native WireJac agent graph."""

import os;
import from orchestrator.adapters {
    jac_mcp_allows_tool,
    workspace_has_jac_mcp
}
import from orchestrator.graph { GraphSnapshot, ensure_graph, validate_plan }
import from orchestrator.models { ImpactPlan }
import from orchestrator.hardware_bridge { hardware_request_for_change }
import from hardware.contracts { ExecutionMode }


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


test "jac mcp is scoped to the Jac device agent" {
    assert not workspace_has_jac_mcp("client");
    assert workspace_has_jac_mcp("device");
    assert not workspace_has_jac_mcp("server");
    assert not workspace_has_jac_mcp("coordinator");
    assert jac_mcp_allows_tool("validate_jac");
    assert jac_mcp_allows_tool("get_resource");
    assert not jac_mcp_allows_tool("run_jac");
    assert not jac_mcp_allows_tool("graph_visualize");
    assert not jac_mcp_allows_tool("execute_command");
}


test "hardware requests use live planning with a safe default mode" {
    os.environ["WIREJAC_HARDWARE_MODE"] = "plan";
    request = hardware_request_for_change(
        "test-device-route",
        "Build an ESP32 motion collector with a GY-521 and button",
        "Create the embedded implementation"
    );
    assert request.execution_mode == ExecutionMode.PLAN;
    assert request.metadata["graph_request_id"] == "test-device-route";
    assert "generation" not in request.metadata;
    assert "gy521-mpu6050" in request.allowed_inventory;
}


test "hardware flash requests select the guarded deploy mode" {
    os.environ["WIREJAC_HARDWARE_MODE"] = "";
    request = hardware_request_for_change(
        "test-device-flash",
        "Flash an ESP32 motion collector with a GY-521 and button",
        "Deploy the embedded implementation"
    );
    assert request.execution_mode == ExecutionMode.DEPLOY;
}


test "graph snapshot exposes all six nodes" {
    ensure_graph();
    snapshot = GraphSnapshot();
    root spawn snapshot;
    data = snapshot.reports[0];
    assert data["initialized"];
    assert len(data["nodes"]) == 6;
    assert len(data["edges"]) == 8;
}
