"""Step 4: deterministic policy and resource validation of synthesized templates.

Runs against the CloudFormation JSON that `cdk synth` already produced, so it
needs no AWS calls and no extra dependencies. This is a deliberate floor, not a
replacement for cdk-nag: it catches the handful of mistakes an agent-authored
construct is most likely to make.

Findings are severity-tagged. Only `ERROR` findings fail the step; `WARN`
findings are surfaced but do not block a deploy.
"""

import os;
import json;

import from orchestrator.aws.contracts {
    StepName,
    StepStatus,
    StepResult,
    DeployTarget
}

glob SEVERITY_ERROR: str = "ERROR";
glob SEVERITY_WARN: str = "WARN";


obj Finding {
    has severity: str,
        rule: str,
        resource: str,
        detail: str;
}

"""Render a finding as a single log line."""
def format_finding(finding: Finding) -> str {
    return f"[{finding.severity}] {finding.rule} on {finding.resource}: {finding.detail}";
}


"""Coerce a CloudFormation scalar-or-list field into a list."""
def as_list(value: any) -> list[any] {
    if value is None {
        return [];
    }
    if isinstance(value, list) {
        return value;
    }
    return [value];
}


"""Flag IAM statements that grant every action on every resource."""
def check_wildcard_iam(name: str, resource: dict[str, any]) -> list[Finding] {
    findings: list[Finding] = [];
    properties = resource.get("Properties", {});
    documents = [properties.get("PolicyDocument")];
    for policy in as_list(properties.get("Policies")) {
        if isinstance(policy, dict) {
            documents.append(policy.get("PolicyDocument"));
        }
    }
    for document in documents {
        if not isinstance(document, dict) {
            continue;
        }
        for statement in as_list(document.get("Statement")) {
            if not isinstance(statement, dict) {
                continue;
            }
            if statement.get("Effect") != "Allow" {
                continue;
            }
            actions = as_list(statement.get("Action"));
            resources = as_list(statement.get("Resource"));
            if "*" in actions and "*" in resources {
                findings.append(Finding(
                    severity=SEVERITY_ERROR,
                    rule="iam-wildcard-action-and-resource",
                    resource=name,
                    detail="statement allows Action '*' on Resource '*'"
                ));
            } elif "*" in actions {
                findings.append(Finding(
                    severity=SEVERITY_WARN,
                    rule="iam-wildcard-action",
                    resource=name,
                    detail="statement allows Action '*'"
                ));
            }
        }
    }
    return findings;
}


"""Flag buckets without a public access block."""
def check_bucket_public_access(name: str, resource: dict[str, any]) -> list[Finding] {
    properties = resource.get("Properties", {});
    if properties.get("PublicAccessBlockConfiguration") is None {
        return [Finding(
            severity=SEVERITY_ERROR,
            rule="s3-missing-public-access-block",
            resource=name,
            detail="bucket has no PublicAccessBlockConfiguration"
        )];
    }
    return [];
}


"""Flag security group rules open to the whole internet."""
def check_open_ingress(name: str, resource: dict[str, any]) -> list[Finding] {
    findings: list[Finding] = [];
    properties = resource.get("Properties", {});
    rules = as_list(properties.get("SecurityGroupIngress"));
    if resource.get("Type") == "AWS::EC2::SecurityGroupIngress" {
        rules = [properties];
    }
    for rule in rules {
        if not isinstance(rule, dict) {
            continue;
        }
        cidr = rule.get("CidrIp");
        cidr_v6 = rule.get("CidrIpv6");
        if cidr == "0.0.0.0/0" or cidr_v6 == "::/0" {
            findings.append(Finding(
                severity=SEVERITY_ERROR,
                rule="sg-open-ingress",
                resource=name,
                detail="ingress rule allows traffic from any address"
            ));
        }
    }
    return findings;
}


"""Flag literal credential-shaped values in Lambda environment variables.

Only literal strings are flagged. CloudFormation intrinsics such as Ref or
Fn::GetAtt are dicts and are left alone, as are SSM and Secrets Manager
references, which are the correct way to pass a secret.
"""
def check_env_secrets(name: str, resource: dict[str, any]) -> list[Finding] {
    findings: list[Finding] = [];
    properties = resource.get("Properties", {});
    environment = properties.get("Environment");
    if not isinstance(environment, dict) {
        return findings;
    }
    variables = environment.get("Variables");
    if not isinstance(variables, dict) {
        return findings;
    }
    suspicious = ["SECRET", "PASSWORD", "PASSWD", "TOKEN", "PRIVATE_KEY", "ACCESS_KEY"];
    for (key, value) in variables.items() {
        if not isinstance(value, str) {
            continue;
        }
        upper = key.upper();
        flagged = False;
        for marker in suspicious {
            if marker in upper {
                flagged = True;
            }
        }
        if flagged and value and not value.startswith("{{resolve:") {
            findings.append(Finding(
                severity=SEVERITY_ERROR,
                rule="lambda-literal-secret-env",
                resource=name,
                detail=f"environment variable '{key}' holds a literal value"
            ));
        }
    }
    return findings;
}


"""Apply every rule to one synthesized template."""
def scan_template(template: dict[str, any]) -> list[Finding] {
    findings: list[Finding] = [];
    resources = template.get("Resources", {});
    if not isinstance(resources, dict) {
        return findings;
    }
    for (name, resource) in resources.items() {
        if not isinstance(resource, dict) {
            continue;
        }
        kind = resource.get("Type", "");
        if kind in ["AWS::IAM::Policy", "AWS::IAM::Role", "AWS::IAM::ManagedPolicy"] {
            findings += check_wildcard_iam(name, resource);
        }
        if kind == "AWS::S3::Bucket" {
            findings += check_bucket_public_access(name, resource);
        }
        if kind in ["AWS::EC2::SecurityGroup", "AWS::EC2::SecurityGroupIngress"] {
            findings += check_open_ingress(name, resource);
        }
        if kind == "AWS::Lambda::Function" {
            findings += check_env_secrets(name, resource);
        }
    }
    return findings;
}


"""Validate the synthesized template for this target.

Requires `cdk synth` to have run first; a missing template is itself an error,
since silently passing would let an unsynthesized change reach deploy.
"""
def validate_policy(target: DeployTarget) -> StepResult {
    path = os.path.join(
        target.app_dir, "cdk.out", f"{target.stack_name}.template.json"
    );
    if not os.path.exists(path) {
        return StepResult(
            step=StepName.POLICY,
            status=StepStatus.FAILED,
            summary="no synthesized template to validate",
            error=f"expected template at {path}"
        );
    }
    try {
        handle = open(path, "r");
        template: dict[str, any] = json.load(handle);
        handle.close();
    } except Exception as err {
        return StepResult(
            step=StepName.POLICY,
            status=StepStatus.FAILED,
            summary="synthesized template could not be parsed",
            error=f"{type(err).__name__}: {err}"
        );
    }

    findings = scan_template(template);
    errors = [f for f in findings if f.severity == SEVERITY_ERROR];
    warnings = [f for f in findings if f.severity == SEVERITY_WARN];
    lines = [format_finding(f) for f in findings];

    if errors {
        return StepResult(
            step=StepName.POLICY,
            status=StepStatus.FAILED,
            summary=f"{len(errors)} policy error(s), {len(warnings)} warning(s)",
            error="\n".join(lines)
        );
    }
    return StepResult(
        step=StepName.POLICY,
        status=StepStatus.PASSED,
        summary=f"policy validation passed with {len(warnings)} warning(s)",
        error="\n".join(lines) if lines else ""
    );
}
