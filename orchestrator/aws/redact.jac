"""Redaction for CDK CLI output before it reaches an event, log, or dashboard.

`cdk diff` and `cdk deploy` output routinely contain IAM policy statements,
principals, and Lambda environment variable values. The dashboard event
contract requires that secrets are scrubbed before serialization and that long
output is referenced rather than embedded. Everything leaving the pipeline
passes through `redact`.
"""

import re;

glob PLACEHOLDER: str = "[REDACTED]";

glob SECRET_PATTERNS: list[str] = [
    r"(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}",
    r"aws_secret_access_key\s*=\s*\S+",
    r"aws_session_token\s*=\s*\S+",
    r"(?i)bearer\s+[A-Za-z0-9\-._~+/]{20,}",
    r"(?i)\b(?:sk|pk)-[A-Za-z0-9]{16,}",
    r"(?i)\"?(?:password|passwd|secret|api[_-]?key|access[_-]?token|session[_-]?token|private[_-]?key)\"?\s*[:=]\s*\"?[^\s\",}]{4,}\"?"
];

glob SENSITIVE_SECTIONS: list[str] = [
    "IAM Statement Changes",
    "IAM Policy Changes",
    "Security Group Changes"
];

"""Keep only the last four digits of a 12-digit AWS account id."""
def mask_account_id(text: str) -> str {
    return re.sub(r"\b(\d{8})(\d{4})\b", r"********\2", text);
}

"""Replace known credential shapes with a placeholder."""
def scrub_secrets(text: str) -> str {
    out = text;
    for pattern in SECRET_PATTERNS {
        out = re.sub(pattern, PLACEHOLDER, out);
    }
    return out;
}

"""Replace IAM and security-group diff bodies with a one-line marker.

cdk diff renders full policy statements and principals in these tables. The
dashboard needs to know that they changed, not what they say.
"""
def drop_sensitive_sections(text: str) -> str {
    lines = text.split("\n");
    kept: list[str] = [];
    skipping = False;
    for line in lines {
        stripped = line.strip();
        is_header = False;
        for section in SENSITIVE_SECTIONS {
            if stripped.startswith(section) {
                is_header = True;
            }
        }
        if is_header {
            kept.append(f"{stripped} (details withheld)");
            skipping = True;
            continue;
        }
        if skipping {
            if stripped == "" {
                skipping = False;
            }
            continue;
        }
        kept.append(line);
    }
    return "\n".join(kept);
}

"""Full redaction pass applied before any text reaches an event or log."""
def redact(text: str, max_chars: int = 4000) -> str {
    out = drop_sensitive_sections(text);
    out = scrub_secrets(out);
    out = mask_account_id(out);
    if len(out) > max_chars {
        dropped = len(out) - max_chars;
        out = out[:max_chars] + f"\n... [{dropped} chars truncated]";
    }
    return out;
}
