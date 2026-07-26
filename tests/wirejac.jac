"""Tests for the Jac-native WireJac agent graph."""

import os;
import from orchestrator.adapters {
    deploy,
    jac_mcp_allows_tool,
    workspace_has_jac_mcp
}
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


test "jac mcp is scoped to client and device agents" {
    assert workspace_has_jac_mcp("client");
    assert workspace_has_jac_mcp("device");
    assert not workspace_has_jac_mcp("server");
    assert not workspace_has_jac_mcp("coordinator");
    assert jac_mcp_allows_tool("validate_jac");
    assert jac_mcp_allows_tool("get_resource");
    assert not jac_mcp_allows_tool("run_jac");
    assert not jac_mcp_allows_tool("graph_visualize");
    assert not jac_mcp_allows_tool("execute_command");
}


test "mock request traverses the client-only route" {
    os.environ["WIREJAC_MOCK"] = "1";
    os.environ["WIREJAC_EVENT_FILE"] = "/tmp/wirejac-test-events.jsonl";
    ensure_graph();
    request = ChangeRequest(
        prompt="Make the sample count more prominent",
        request_id="test-client-route"
    );
    root spawn request;

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


test "aws intent routes to the approval gate in mock mode" {
    os.environ["WIREJAC_MOCK"] = "1";
    result = deploy(["server"], "aws_cdk", "test-aws-route");
    assert result.success;
    assert result.awaiting_approval;
    assert result.artifact == "mock-change-hash";
}


test "store history prompt stops at aws approval in mock mode" {
    os.environ["WIREJAC_MOCK"] = "1";
    os.environ["WIREJAC_EVENT_FILE"] = "/tmp/wirejac-test-events-aws.jsonl";
    ensure_graph();
    request = ChangeRequest(
        prompt="Store the accelerometer readings so the dashboard can show history",
        request_id="test-aws-history"
    );
    root spawn request;

    assert not request.failed;
    assert "server" in request.plan.selected;
    assert "client" in request.plan.selected;
    assert request.plan.deployment_intent == "aws_cdk";
    assert request.deployment_result.awaiting_approval;
    visited = [event.node_name for event in request.activations];
    assert "deployment" in visited;
    assert "monitoring" not in visited;
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
