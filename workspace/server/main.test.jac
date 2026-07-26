"""Tests for the accelerometer sample API (in-memory store).

Annex of workspace/server/main.jac — run from that directory or pass this
file path to `jac test`.
"""

import os;
import from typing { cast }


test "health reports memory store by default" {
    os.environ.pop("WIREJAC_SAMPLES_TABLE", None);
    status = health();
    assert status.status == "ok";
    assert status.store == "memory";
}


test "post and get samples round-trip in memory" {
    os.environ.pop("WIREJAC_SAMPLES_TABLE", None);
    os.environ.pop("WIREJAC_API_KEY", None);
    accepted = post_sample(
        device_id="esp32-01",
        captured_at_ms=1720000000000,
        x=0.12,
        y=-0.08,
        z=9.74,
        session_id="training-001",
        label="baseline"
    );
    assert accepted.accepted;
    assert accepted.sample_id;

    listed = get_samples(session_id="training-001");
    assert listed.session_id == "training-001";
    assert len(listed.samples) >= 1;
    last = listed.samples[len(listed.samples) - 1];
    assert last.device_id == "esp32-01";
    assert last.x == 0.12;
    assert last.label == "baseline";
}


test "session_id defaults to device_id" {
    os.environ.pop("WIREJAC_SAMPLES_TABLE", None);
    os.environ.pop("WIREJAC_API_KEY", None);
    put_sample("esp32-02", "", 1720000001000, 1.0, 2.0, 3.0, None);
    rows = list_samples("esp32-02");
    assert len(rows) >= 1;
    assert cast(dict, rows[len(rows) - 1])["session_id"] == "esp32-02";
}


test "api key required when WIREJAC_API_KEY is set" {
    os.environ.pop("WIREJAC_SAMPLES_TABLE", None);
    os.environ["WIREJAC_API_KEY"] = "team-secret";
    try {
        get_samples(session_id="training-001", api_key="wrong");
        assert False;
    } except PermissionError {
        assert True;
    }
    listed = get_samples(session_id="training-001", api_key="team-secret");
    assert listed.session_id == "training-001";
    os.environ.pop("WIREJAC_API_KEY", None);
}
