"""Tests for the Wirejac AWS backend modules.

Covers the parts that must be correct without touching AWS: redaction, the
policy rules, and the approval binding. The CDK invocations themselves are
exercised separately against the real stack, since steps 1-5 mutate nothing.
"""

import from orchestrator.aws.contracts {
    StepName,
    StepStatus,
    StepResult,
    DeployTarget,
    PipelineResult,
    InfraKind,
    InfraRequest
}
import from orchestrator.aws.redact {
    redact,
    scrub_secrets,
    mask_account_id,
    drop_sensitive_sections
}
import from orchestrator.aws.policy { scan_template, SEVERITY_ERROR, SEVERITY_WARN }
import from orchestrator.aws.fulfill {
    server_infra_needs,
    infra_catalog_ready,
    intent_for_server_infra,
    resolve_against_catalog
}


test "redact strips access key ids" {
    out = scrub_secrets("using AKIAIOSFODNN7EXAMPLE here");
    assert "AKIAIOSFODNN7EXAMPLE" not in out;
    assert "[REDACTED]" in out;
}

test "redact strips credential assignments" {
    out = scrub_secrets("aws_secret_access_key = wJalrXUtnFEMIK7MDENGbPxRfiCY");
    assert "wJalrXUtnFEMIK7MDENGbPxRfiCY" not in out;
}

test "redact strips labelled secrets" {
    out = scrub_secrets('"password": "hunter2000"');
    assert "hunter2000" not in out;
}

test "mask account id keeps last four" {
    out = mask_account_id("arn:aws:iam::852353855241:role/Foo");
    assert "852353855241" not in out;
    assert "5241" in out;
}

test "drop sensitive sections withholds iam table" {
    text = "\n".join([
        "Stack WirejacDevStack",
        "IAM Statement Changes",
        "| + | arn:aws:iam::1234:role/Foo | Allow | sts:AssumeRole |",
        "",
        "Resources",
        "[+] AWS::SSM::Parameter Marker"
    ]);
    out = drop_sensitive_sections(text);
    assert "sts:AssumeRole" not in out;
    assert "details withheld" in out;
    assert "AWS::SSM::Parameter Marker" in out;
}

test "redact truncates long output" {
    out = redact("x" * 500, max_chars=100);
    assert len(out) < 200;
    assert "truncated" in out;
}


test "policy flags wildcard iam" {
    template: dict[str, any] = {
        "Resources": {
            "WideOpen": {
                "Type": "AWS::IAM::Policy",
                "Properties": {
                    "PolicyDocument": {
                        "Statement": [
                            {"Effect": "Allow", "Action": "*", "Resource": "*"}
                        ]
                    }
                }
            }
        }
    };
    findings = scan_template(template);
    assert len(findings) == 1;
    assert findings[0].severity == SEVERITY_ERROR;
    assert findings[0].rule == "iam-wildcard-action-and-resource";
}

test "policy warns on wildcard action only" {
    template: dict[str, any] = {
        "Resources": {
            "Broad": {
                "Type": "AWS::IAM::Policy",
                "Properties": {
                    "PolicyDocument": {
                        "Statement": [
                            {
                                "Effect": "Allow",
                                "Action": "*",
                                "Resource": "arn:aws:s3:::bucket/*"
                            }
                        ]
                    }
                }
            }
        }
    };
    findings = scan_template(template);
    assert len(findings) == 1;
    assert findings[0].severity == SEVERITY_WARN;
}

test "policy flags bucket without public access block" {
    template: dict[str, any] = {
        "Resources": {
            "Bucket": {"Type": "AWS::S3::Bucket", "Properties": {}}
        }
    };
    findings = scan_template(template);
    assert len(findings) == 1;
    assert findings[0].rule == "s3-missing-public-access-block";
}

test "policy accepts bucket with public access block" {
    template: dict[str, any] = {
        "Resources": {
            "Bucket": {
                "Type": "AWS::S3::Bucket",
                "Properties": {
                    "PublicAccessBlockConfiguration": {"BlockPublicAcls": True}
                }
            }
        }
    };
    assert len(scan_template(template)) == 0;
}

test "policy flags open security group" {
    template: dict[str, any] = {
        "Resources": {
            "Sg": {
                "Type": "AWS::EC2::SecurityGroup",
                "Properties": {
                    "SecurityGroupIngress": [
                        {"CidrIp": "0.0.0.0/0", "FromPort": 22}
                    ]
                }
            }
        }
    };
    findings = scan_template(template);
    assert len(findings) == 1;
    assert findings[0].rule == "sg-open-ingress";
}

test "policy flags literal secret in lambda env" {
    template: dict[str, any] = {
        "Resources": {
            "Fn": {
                "Type": "AWS::Lambda::Function",
                "Properties": {
                    "Environment": {"Variables": {"API_TOKEN": "abc123literal"}}
                }
            }
        }
    };
    findings = scan_template(template);
    assert len(findings) == 1;
    assert findings[0].rule == "lambda-literal-secret-env";
}

test "policy allows intrinsic and resolved env values" {
    template: dict[str, any] = {
        "Resources": {
            "Fn": {
                "Type": "AWS::Lambda::Function",
                "Properties": {
                    "Environment": {
                        "Variables": {
                            "DB_SECRET": {"Ref": "SomeSecret"},
                            "API_TOKEN": "{{resolve:secretsmanager:tok}}"
                        }
                    }
                }
            }
        }
    };
    assert len(scan_template(template)) == 0;
}

test "policy passes the real marker stack" {
    template: dict[str, any] = {
        "Resources": {
            "StackStatus": {
                "Type": "AWS::SSM::Parameter",
                "Properties": {"Value": "ready", "Type": "String"}
            }
        }
    };
    assert len(scan_template(template)) == 0;
}


test "approval requires a grant" {
    assert not verify_approval(None, "req-1", "some diff");
}

test "approval is bound to the request" {
    grant = ApprovalGrant(
        request_id="req-1",
        change_hash=change_hash("some diff"),
        approved_by="operator"
    );
    assert verify_approval(grant, "req-1", "some diff");
    assert not verify_approval(grant, "req-2", "some diff");
}

test "approval is invalidated when the diff changes" {
    grant = ApprovalGrant(
        request_id="req-1",
        change_hash=change_hash("original diff"),
        approved_by="operator"
    );
    assert not verify_approval(grant, "req-1", "a different diff");
}


test "executables outside the allowlist are refused" {
    out = exec_command(["rm", "-rf", "/"], ".");
    assert out.exit_code == 126;
    assert "not allowlisted" in out.text;
}

test "empty commands are refused" {
    assert exec_command([], ".").exit_code == 126;
}


test "deploy target omits profile flag when unset" {
    assert DeployTarget().cli_env_flags() == [];
    assert DeployTarget(profile="wirejac").cli_env_flags() == [
        "--profile", "wirejac"
    ];
}

test "pipeline result surfaces the failing step" {
    result = PipelineResult(target=DeployTarget());
    result.record(StepResult(step=StepName.BUILD, status=StepStatus.PASSED));
    result.record(StepResult(
        step=StepName.TEST, status=StepStatus.FAILED, summary="tests failed"
    ));
    failed = result.failed_step();
    assert failed is not None;
    assert failed.step == StepName.TEST;
}

test "infra request defaults to unfulfilled" {
    request = InfraRequest(
        request_id="req-1",
        requested_by="backend",
        kind=InfraKind.DATA,
        resource_name="SamplesTable"
    );
    assert not request.fulfilled;
}


test "server infra needs include SamplesTable in the catalog" {
    needs = server_infra_needs("req-catalog");
    assert len(needs) == 1;
    assert needs[0].resource_name == "SamplesTable";
    assert needs[0].kind == InfraKind.DATA;
    assert infra_catalog_ready(needs);
    resolved = resolve_against_catalog(needs);
    assert resolved[0].fulfilled;
}


test "unknown infra stays unfulfilled" {
    request = InfraRequest(
        request_id="req-2",
        requested_by="server",
        kind=InfraKind.DATA,
        resource_name="MysteryTable"
    );
    resolved = resolve_against_catalog([request]);
    assert not resolved[0].fulfilled;
    assert not infra_catalog_ready([request]);
    assert intent_for_server_infra([request]) == "provision_infra";
}
