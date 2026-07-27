"""Resume one persisted hardware job after an interrupted runner."""

import json;
import os;
import from hardware.api { _get_job }
import from hardware.contracts { JobStatus }
import from hardware.integration { _register_hardware_service }
import from hardware.orchestration { _run_job }


with entry:__main__ {
    job_id = os.environ.get("WIREJAC_JOB_ID", "").strip();
    if not job_id {
        raise ValueError("WIREJAC_JOB_ID is required");
    }
    _register_hardware_service();
    before = _get_job(job_id);
    if before is None {
        raise ValueError("Hardware job was not found");
    }
    print(json.dumps({
        "job_id": job_id,
        "resume_from_status": before.job.status,
        "resume_from_phase": before.job.phase,
    }, sort_keys=True));
    _ = _run_job(job_id);
    after = _get_job(job_id);
    if after is None {
        raise RuntimeError("Hardware job disappeared after resume");
    }
    print(json.dumps({
        "job_id": job_id,
        "status": after.job.status,
        "phase": after.job.phase,
        "error_code": after.job.error_code,
        "error_message": after.job.error_message,
        "artifact_count": len(after.artifacts),
    }, sort_keys=True, indent=2));
    if after.job.status not in [
        JobStatus.SUCCEEDED,
        JobStatus.FAILED,
        JobStatus.BLOCKED,
        JobStatus.ROLLED_BACK,
    ] {
        raise RuntimeError("Hardware job did not reach a terminal state");
    }
}
