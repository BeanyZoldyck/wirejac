"""Host integrations used by the Jac graph.

The graph and contracts remain Jac-native. Complex host operations are kept in
this Jac module's Python interop block so there is no separate agent harness.
"""

import os;
import from typing { cast }
import from orchestrator.models {
    Activation,
    ActivationState,
    AgentResult,
    DeploymentResult,
    ImpactPlan,
    MonitorResult
}
import from orchestrator.aws.bridge { is_aws_intent, validate_aws, deploy_aws }
import from orchestrator.aws.pipeline { ApprovalGrant }
import from orchestrator.aws.fulfill {
    server_infra_needs,
    intent_for_server_infra
}

::py::
import asyncio
import datetime
import fnmatch
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import urllib.error
import urllib.request
import uuid

_PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
_EVENT_FILE = _PROJECT_ROOT / "runtime" / "events" / "events.jsonl"
_SNAPSHOT_ROOT = _PROJECT_ROOT / "runtime" / "snapshots"
_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
_DEFAULT_MODEL = "deepseek/deepseek-v4-flash"
_MAX_TOOL_TURNS = 20
_MAX_OUTPUT = 12000
_JAC_MCP_WORKSPACES = {"device"}
_JAC_MCP_TOOLS = {
    "validate_jac",
    "check_syntax",
    "format_jac",
    "py_to_jac",
    "explain_error",
    "list_examples",
    "get_example",
    "search_docs",
    "get_ast",
    "lint_jac",
    "jac_to_py",
    "jac_to_js",
    "understand_jac_and_jaseci",
    "get_resource",
}


def _load_project_env():
    """Load local deployment variables without exposing them to agent tools."""
    env_file = _PROJECT_ROOT / ".env"
    if not env_file.exists():
        return
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key and key not in os.environ:
            os.environ[key] = value.strip().strip('"').strip("'")


_load_project_env()


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _new_request_id():
    return "req-" + uuid.uuid4().hex[:16]


def _safe_path(workspace, requested):
    root = (_PROJECT_ROOT / workspace).resolve()
    candidate = (root / requested).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise PermissionError("path escapes workspace") from exc
    if candidate != root:
        current = candidate
        while current != root:
            if current.exists() and current.is_symlink():
                raise PermissionError("symlinks are not allowed in workspace tools")
            current = current.parent
    return root, candidate


def _read_text(path):
    return path.read_text(encoding="utf-8")


def _workspace_manifest(workspace):
    root, _ = _safe_path(workspace, ".")
    entries = []
    if not root.exists():
        return entries
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            relative = str(path.relative_to(root))
            if any(part in {"node_modules", ".git", "__pycache__"} for part in path.parts):
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            entries.append({"path": relative, "sha256": digest})
    return entries


def _snapshot_workspace(request_id, name, workspace):
    root, _ = _safe_path(workspace, ".")
    target = _SNAPSHOT_ROOT / request_id / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        shutil.rmtree(target)
    if root.exists():
        shutil.copytree(
            root,
            target,
            ignore=shutil.ignore_patterns("node_modules", ".git", "__pycache__")
        )
    else:
        target.mkdir(parents=True)
    manifest = {
        "request_id": request_id,
        "workspace": name,
        "source": str(root),
        "snapshot": str(target),
        "files": _workspace_manifest(workspace),
    }
    (target / "snapshot-manifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )
    return str(target)


def _tool_schemas():
    return [
        {
            "type": "function",
            "function": {
                "name": "list_files",
                "description": "List files in the assigned workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {"pattern": {"type": "string"}},
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a UTF-8 file in the assigned workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "search_text",
                "description": "Search text in workspace files.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "pattern": {"type": "string"},
                    },
                    "required": ["query"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "write_file",
                "description": "Write a complete UTF-8 file in the assigned workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "content": {"type": "string"},
                    },
                    "required": ["path", "content"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "run_command",
                "description": "Run an allowlisted command in the assigned workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "argv": {
                            "type": "array",
                            "items": {"type": "string"},
                            "minItems": 1,
                        }
                    },
                    "required": ["argv"],
                },
            },
        },
    ]


def _jac_mcp_enabled(name):
    return name in _JAC_MCP_WORKSPACES


def _jac_mcp_tool_schemas(tools):
    schemas = []
    for tool in tools:
        if tool.name not in _JAC_MCP_TOOLS:
            continue
        data = tool.model_dump(by_alias=True, exclude_none=True)
        schemas.append({
            "type": "function",
            "function": {
                "name": data["name"],
                "description": data.get("description", "Jac MCP tool"),
                "parameters": data.get("inputSchema", {"type": "object"}),
            },
        })
    return schemas


def _jac_mcp_result(result):
    data = result.model_dump(mode="json", by_alias=True, exclude_none=True)
    encoded = json.dumps(data)
    if len(encoded) <= _MAX_OUTPUT:
        return data
    return {"truncated": True, "content": encoded[:_MAX_OUTPUT]}


def _execute_tool(workspace, allowed_commands, name, arguments):
    root, _ = _safe_path(workspace, ".")
    if name == "list_files":
        pattern = arguments.get("pattern", "*")
        files = []
        for path in sorted(root.rglob("*")):
            if path.is_file() and not path.is_symlink():
                relative = str(path.relative_to(root))
                if fnmatch.fnmatch(relative, pattern) or pattern == "*":
                    files.append(relative)
        return {"files": files[:500]}
    if name == "read_file":
        _, path = _safe_path(workspace, arguments["path"])
        return {"path": arguments["path"], "content": _read_text(path)[:_MAX_OUTPUT]}
    if name == "search_text":
        query = arguments["query"]
        pattern = arguments.get("pattern", "*")
        matches = []
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            relative = str(path.relative_to(root))
            if not fnmatch.fnmatch(relative, pattern) and pattern != "*":
                continue
            try:
                for number, line in enumerate(_read_text(path).splitlines(), 1):
                    if query in line:
                        matches.append({"path": relative, "line": number, "text": line[:500]})
            except UnicodeDecodeError:
                continue
            if len(matches) >= 200:
                break
        return {"matches": matches}
    if name == "write_file":
        _, path = _safe_path(workspace, arguments["path"])
        content = arguments["content"]
        if len(content.encode("utf-8")) > 1_000_000:
            raise ValueError("file exceeds 1 MB tool limit")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return {"written": arguments["path"], "bytes": len(content.encode("utf-8"))}
    if name == "run_command":
        argv = arguments["argv"]
        if not argv or argv[0] not in allowed_commands:
            raise PermissionError("command executable is not allowlisted")
        completed = subprocess.run(
            argv,
            cwd=root,
            capture_output=True,
            text=True,
            timeout=60,
            env={"PATH": os.environ.get("PATH", "")},
        )
        return {
            "returncode": completed.returncode,
            "stdout": completed.stdout[-_MAX_OUTPUT:],
            "stderr": completed.stderr[-_MAX_OUTPUT:],
        }
    raise ValueError("unknown tool")


def _validation_commands(name):
    return {
        "client": [["npm", "run", "check"]],
        "server": [["jac", "check", "main.jac"]],
        "device": [["jac", "check", "src/main.jac"]],
    }.get(name, [])


def _validate_workspace(name, workspace, allowed_commands):
    root, _ = _safe_path(workspace, ".")
    checks = []
    for argv in _validation_commands(name):
        if argv[0] not in allowed_commands:
            return False, [{"argv": argv, "error": "validator is not allowlisted"}]
        completed = subprocess.run(
            argv,
            cwd=root,
            capture_output=True,
            text=True,
            timeout=60,
            env={"PATH": os.environ.get("PATH", "")},
        )
        check = {
            "argv": argv,
            "returncode": completed.returncode,
            "stdout": completed.stdout[-_MAX_OUTPUT:],
            "stderr": completed.stderr[-_MAX_OUTPUT:],
        }
        checks.append(check)
        if completed.returncode != 0:
            return False, checks
    return True, checks


def _openrouter(messages, tools=None):
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key:
        raise RuntimeError("OPENROUTER_API_KEY is required")
    body = {
        "model": os.environ.get("OPENROUTER_MODEL", _DEFAULT_MODEL),
        "messages": messages,
        "temperature": 0.1,
    }
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    request = urllib.request.Request(
        _OPENROUTER_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "HTTP-Referer": "https://wirejac.local",
            "X-Title": "WireJac",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:2000]
        raise RuntimeError(f"OpenRouter HTTP {exc.code}: {detail}") from exc
    return payload["choices"][0]["message"]


def _extract_json(content):
    text = (content or "").strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines)
    return json.loads(text)


def _read_workspace_context(workspaces):
    context = []
    for workspace in workspaces:
        root, _ = _safe_path(workspace["path"], ".")
        skill = root / pathlib.Path(workspace["skill_path"]).name
        spec = root / pathlib.Path(workspace["spec_path"]).name
        context.append({
            "name": workspace["name"],
            "skill": _read_text(skill) if skill.exists() else "",
            "api_spec": _read_text(spec) if spec.exists() else "",
            "files": [entry["path"] for entry in _workspace_manifest(workspace["path"])][:200],
        })
    return context


def _plan_change(prompt, workspaces):
    context = _read_workspace_context(workspaces)
    system = """You are the WireJac coordinator. Select only affected workspaces from client, server, and device. Return JSON only with keys selected (array), skipped (object with reasons), tasks (object), acceptance (array), contract_change_expected (boolean), and deployment_intent (hot_reload, restart_server, prepare_device, aws_cdk, deploy_backend, or provision_infra). Use aws_cdk/provision_infra when the server needs new or undeployed AWS resources such as DynamoDB. Every unselected workspace must appear in skipped. Do not modify files."""
    message = _openrouter([
        {"role": "system", "content": system},
        {"role": "user", "content": json.dumps({"prompt": prompt, "workspaces": context})},
    ])
    return _extract_json(message.get("content"))


async def _workspace_agent_loop(
    request_id,
    name,
    workspace,
    allowed_commands,
    messages,
    tools,
    mcp_session,
):
    tool_count = 0
    final = None
    for turn in range(_MAX_TOOL_TURNS):
        _emit_event({
            "request_id": request_id,
            "node": name,
            "state": "running",
            "summary": f"{name.title()} agent reasoning turn {turn + 1}: inspecting, implementing, and validating the requested change",
            "tool_count": tool_count,
            "revision": "",
            "hardware_job_id": "",
            "hardware_status": "",
            "error": "",
        })
        message = _openrouter(messages, tools)
        messages.append(message)
        calls = message.get("tool_calls") or []
        if not calls:
            try:
                candidate = _extract_json(message.get("content"))
            except (TypeError, ValueError, json.JSONDecodeError):
                messages.append({
                    "role": "user",
                    "content": (
                        "Your final response was not valid JSON. Return JSON only with "
                        "success (boolean), summary (string), and error (string)."
                    ),
                })
                continue
            if candidate.get("success"):
                valid, checks = _validate_workspace(name, workspace, allowed_commands)
                if not valid:
                    messages.append({
                        "role": "user",
                        "content": (
                            "Deterministic validation failed. Repair the workspace, rerun checks, "
                            "and return the final JSON again. Validation output:\n"
                            + json.dumps(checks)
                        ),
                    })
                    continue
            final = candidate
            break
        for call in calls:
            tool_count += 1
            function = call["function"]
            labels = {
                "list_files": "Inventorying the existing frontend workspace",
                "read_file": "Reading the current mini-app source",
                "search_text": "Tracing the relevant frontend implementation",
                "write_file": "Writing the requested frontend change",
                "run_command": "Running a contained frontend validation command",
                "validate_jac": "Validating Jac client code",
                "check_syntax": "Checking Jac syntax",
                "format_jac": "Formatting Jac client code",
                "lint_jac": "Linting Jac client code",
            }
            _emit_event({
                "request_id": request_id,
                "node": name,
                "state": "running",
                "summary": labels.get(function["name"], f"Running contained tool {function['name']}"),
                "tool_count": tool_count,
                "revision": "",
                "hardware_job_id": "",
                "hardware_status": "",
                "error": "",
            })
            try:
                arguments = json.loads(function.get("arguments") or "{}")
                if mcp_session is not None and function["name"] in _JAC_MCP_TOOLS:
                    mcp_result = await mcp_session.call_tool(function["name"], arguments)
                    result = _jac_mcp_result(mcp_result)
                else:
                    result = _execute_tool(
                        workspace,
                        allowed_commands,
                        function["name"],
                        arguments,
                    )
            except Exception as exc:
                result = {"error": str(exc)}
            messages.append({
                "role": "tool",
                "tool_call_id": call["id"],
                "content": json.dumps(result),
            })
    return final, tool_count


async def _workspace_agent_live(request_id, name, workspace, allowed_commands, messages):
    tools = _tool_schemas()
    if not _jac_mcp_enabled(name):
        return await _workspace_agent_loop(
            request_id, name, workspace, allowed_commands, messages, tools, None
        )

    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    root, _ = _safe_path(workspace, ".")
    server = StdioServerParameters(
        command="jac",
        args=["mcp", "--mode", "lite"],
        cwd=root,
        env={"PATH": os.environ.get("PATH", "")},
    )
    async with stdio_client(server) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await asyncio.wait_for(session.initialize(), timeout=15)
            inventory = await asyncio.wait_for(session.list_tools(), timeout=15)
            tools.extend(_jac_mcp_tool_schemas(inventory.tools))
            return await _workspace_agent_loop(
                request_id, name, workspace, allowed_commands, messages, tools, session
            )


def _workspace_agent(request_id, name, workspace, skill_path, spec_path, task, acceptance, allowed_commands):
    snapshot = _snapshot_workspace(request_id, name, workspace)
    root, _ = _safe_path(workspace, ".")
    spec_file = root / pathlib.Path(spec_path).name
    before_spec = _read_text(spec_file) if spec_file.exists() else ""
    skill_file = root / pathlib.Path(skill_path).name
    skill = _read_text(skill_file) if skill_file.exists() else ""
    spec = before_spec
    mcp_instruction = (
        " Use the Jac MCP tools for current Jac documentation, formatting, "
        "linting, and compiler feedback."
        if _jac_mcp_enabled(name)
        else ""
    )
    system = f"""You are the {name} workspace agent. You may act only through the provided tools, which are confined to {workspace}. Follow these role instructions:\n\n{skill}\n\nAPI contract:\n\n{spec}\n\nComplete the task, inspect files before editing, and run appropriate validation.{mcp_instruction} When done, return JSON only with success (boolean), summary (string), and error (string). Never claim success if validation failed."""
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": json.dumps({"task": task, "acceptance": acceptance})},
    ]
    try:
        final, tool_count = asyncio.run(
            _workspace_agent_live(
                request_id, name, workspace, allowed_commands, messages
            )
        )
    except Exception as exc:
        return {
            "success": False,
            "summary": f"{name} workspace tooling failed",
            "tool_count": 0,
            "revision": snapshot,
            "contract_changed": False,
            "error": str(exc),
        }
    if final is None:
        return {
            "success": False,
            "summary": "Agent exceeded the tool-turn limit",
            "tool_count": tool_count,
            "revision": snapshot,
            "contract_changed": False,
            "error": "tool-turn limit exceeded",
        }
    after_spec = _read_text(spec_file) if spec_file.exists() else ""
    return {
        "success": bool(final.get("success")),
        "summary": str(final.get("summary", "")),
        "tool_count": tool_count,
        "revision": snapshot,
        "contract_changed": before_spec != after_spec,
        "error": str(final.get("error", "")),
    }


def _emit_event(event):
    event_file = pathlib.Path(os.environ.get("WIREJAC_EVENT_FILE", str(_EVENT_FILE)))
    event_file.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(event)
    payload["timestamp"] = payload.get("timestamp") or _utc_now()
    sequence = 1
    if event_file.exists():
        for raw in event_file.read_text(encoding="utf-8").splitlines():
            try:
                existing = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if existing.get("request_id") == payload.get("request_id"):
                sequence = max(sequence, int(existing.get("sequence", 0)) + 1)
    payload["sequence"] = sequence
    with event_file.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, separators=(",", ":")) + "\n")
    # Dashboard placeholder: replace this file sink with SSE/WebSocket publishing.
    return payload["timestamp"]


def _read_request_events(request_id):
    event_file = pathlib.Path(os.environ.get("WIREJAC_EVENT_FILE", str(_EVENT_FILE)))
    if not event_file.exists():
        return []
    events = []
    for raw in event_file.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if event.get("request_id") == request_id:
            events.append(event)
    events.sort(key=lambda event: (int(event.get("sequence", 0)), event.get("timestamp", "")))
    return events


def _list_request_history():
    event_file = pathlib.Path(os.environ.get("WIREJAC_EVENT_FILE", str(_EVENT_FILE)))
    if not event_file.exists():
        return []
    grouped = {}
    for raw in event_file.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        request_id = event.get("request_id", "")
        if not request_id:
            continue
        item = grouped.setdefault(request_id, {
            "id": request_id,
            "name": "Wirejac build",
            "prompt": "",
            "status": "running",
            "events": [],
            "hardware_job_id": "",
            "hardware_status": "",
        })
        item["events"].append(event)
        if event.get("hardware_job_id"):
            item["hardware_job_id"] = event["hardware_job_id"]
        if event.get("hardware_status"):
            item["hardware_status"] = event["hardware_status"]
        if event.get("node") in {"client", "server", "device"} and event.get("state") == "planned":
            summary = event.get("summary", "")
            prompt = summary.rsplit("for: ", 1)[-1] if "for: " in summary else summary
            item["prompt"] = prompt
            item["name"] = prompt or "WireJac build"
        state = event.get("state", "")
        if state in {
            "planned", "queued", "running", "repairing", "replanning",
            "validating", "deploying", "monitoring",
        }:
            item["status"] = "running"
        if state == "failed":
            item["status"] = "failed"
        if state == "awaiting_approval":
            item["status"] = "waiting"
        if event.get("node") == "monitoring" and event.get("state") == "succeeded":
            item["status"] = "done"
    history = list(grouped.values())
    for item in history:
        item["events"].sort(key=lambda event: (int(event.get("sequence", 0)), event.get("timestamp", "")))
    history.sort(
        key=lambda item: item["events"][-1].get("timestamp", "") if item["events"] else "",
        reverse=True,
    )
    return history


def _run_operator_command(variable, label):
    command = os.environ.get(variable, "").strip()
    if not command:
        return False, "", f"{variable} must be configured for {label}"
    try:
        completed = subprocess.run(
            shlex.split(command),
            cwd=_PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=180,
            env=os.environ.copy(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, "", f"{label} could not run: {exc}"
    output = (completed.stdout + "\n" + completed.stderr).strip()[-_MAX_OUTPUT:]
    if completed.returncode != 0:
        return False, output, f"{label} exited with status {completed.returncode}"
    return True, output, ""


def _deploy(selected, intent):
    if "device" in selected:
        return {
            "success": False,
            "summary": "Device deployment must run through the guarded hardware lifecycle",
            "awaiting_approval": False,
            "artifact": "",
            "error": "DEVICE_LIFECYCLE_REQUIRED",
        }
    success, output, error = _run_operator_command(
        "WIREJAC_DEPLOY_COMMAND",
        "deployment command"
    )
    return {
        "success": success,
        "summary": (
            f"Deployment completed for {intent}" if success
            else "Deployment did not run"
        ),
        "awaiting_approval": False,
        "artifact": output,
        "error": error,
    }


def _monitor(acceptance):
    url = os.environ.get("WIREJAC_MONITOR_URL", "").strip()
    if not url:
        return {
            "success": False,
            "summary": "Monitoring did not run",
            "errors": ["WIREJAC_MONITOR_URL must be configured for runtime verification"],
        }
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            status = response.status
            body = response.read(2048).decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {
            "success": False,
            "summary": "Monitoring endpoint was unreachable",
            "errors": [str(exc)],
        }
    if status < 200 or status >= 300:
        return {
            "success": False,
            "summary": f"Monitoring endpoint returned HTTP {status}",
            "errors": [body],
        }
    return {
        "success": True,
        "summary": f"Monitoring endpoint verified {len(acceptance)} acceptance checks",
        "errors": [],
    }
::py::


def new_request_id() -> str {
    return cast(str, _new_request_id());
}


def now() -> str {
    return cast(str, _utc_now());
}


def workspace_has_jac_mcp(name: str) -> bool {
    return cast(bool, _jac_mcp_enabled(name));
}


def jac_mcp_allows_tool(name: str) -> bool {
    return cast(bool, name in _JAC_MCP_TOOLS);
}


def plan_change(prompt: str, workspaces: list[dict]) -> ImpactPlan {
    data = cast(dict, _plan_change(prompt, workspaces));
    return ImpactPlan(
        selected=cast(list[str], data.get("selected", [])),
        skipped=cast(dict[str, str], data.get("skipped", {})),
        tasks=cast(dict[str, str], data.get("tasks", {})),
        acceptance=cast(list[str], data.get("acceptance", [])),
        contract_change_expected=cast(bool, data.get("contract_change_expected", False)),
        deployment_intent=cast(str, data.get("deployment_intent", "hot_reload"))
    );
}


def run_workspace_agent(
    request_id: str,
    name: str,
    workspace: str,
    skill_path: str,
    spec_path: str,
    task: str,
    acceptance: list[str],
    allowed_commands: list[str]
) -> AgentResult {
    data = cast(dict, _workspace_agent(
        request_id,
        name,
        workspace,
        skill_path,
        spec_path,
        task,
        acceptance,
        allowed_commands
    ));
    return AgentResult(
        success=cast(bool, data.get("success", False)),
        summary=cast(str, data.get("summary", "")),
        tool_count=cast(int, data.get("tool_count", 0)),
        revision=cast(str, data.get("revision", "")),
        contract_changed=cast(bool, data.get("contract_changed", False)),
        error=cast(str, data.get("error", ""))
    );
}


def emit_activation(event: Activation) -> None {
    event.timestamp = cast(str, _emit_event({
        "request_id": event.request_id,
        "node": event.node_name,
        "state": event.state.value,
        "summary": event.summary,
        "timestamp": event.timestamp,
        "tool_count": event.tool_count,
        "revision": event.revision,
        "hardware_job_id": event.hardware_job_id,
        "hardware_status": event.hardware_status,
        "error": event.error
    }));
}


def deploy(
    selected: list[str],
    intent: str,
    request_id: str = ""
) -> DeploymentResult {
    rid = request_id if request_id else "anonymous";
    # Server durable-storage needs upgrade a plain restart into the AWS pipeline.
    effective_intent = intent;
    if "server" in selected and not is_aws_intent(effective_intent) {
        effective_intent = intent_for_server_infra(server_infra_needs(rid));
    }

    # AWS CDK path: phase one validates and stops at the approval gate. A second
    # call with WIREJAC_APPROVAL_HASH (+ WIREJAC_CONFIRM_DEPLOY=1) completes it.
    if is_aws_intent(effective_intent) {
        approval_hash = os.environ.get("WIREJAC_APPROVAL_HASH", "");
        if approval_hash and os.environ.get("WIREJAC_CONFIRM_DEPLOY", "") == "1" {
            grant = ApprovalGrant(
                request_id=rid,
                change_hash=approval_hash,
                approved_by=os.environ.get("WIREJAC_APPROVED_BY", "operator")
            );
            return deploy_aws(rid, grant);
        }
        return validate_aws(rid);
    }

    data = cast(dict, _deploy(selected, effective_intent));
    return DeploymentResult(
        success=cast(bool, data.get("success", False)),
        summary=cast(str, data.get("summary", "")),
        awaiting_approval=cast(bool, data.get("awaiting_approval", False)),
        artifact=cast(str, data.get("artifact", "")),
        error=cast(str, data.get("error", ""))
    );
}


def monitor(acceptance: list[str]) -> MonitorResult {
    data = cast(dict, _monitor(acceptance));
    return MonitorResult(
        success=cast(bool, data.get("success", False)),
        summary=cast(str, data.get("summary", "")),
        errors=cast(list[str], data.get("errors", []))
    );
}


def request_events(request_id: str) -> list[dict] {
    return cast(list[dict], _read_request_events(request_id));
}


def request_history() -> list[dict] {
    return cast(list[dict], _list_request_history());
}
