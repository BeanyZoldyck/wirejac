"""Wirejac accelerometer experiment dashboard."""

cl import from react { useEffect }
cl import "./styles.css";

cl {
    def axis_points(
        samples: list[dict],
        axis: str,
        width: float,
        height: float
    ) -> str {
        if len(samples) < 2 {
            return "";
        }
        values = [float(sample.get(axis, 0.0)) for sample in samples];
        largest = max([abs(value) for value in values] + [1.0]);
        points: list[str] = [];
        for (index, value) in enumerate(values) {
            x = float(index) / float(len(values) - 1) * width;
            y = height / 2.0 - value / largest * (height * 0.38);
            points.append(f"{x:.2f},{y:.2f}");
        }
        return " ".join(points);
    }

    def:pub SignalChart(samples: list[dict]) -> JsxElement {
        width = 1000.0;
        height = 360.0;
        return <div className="chart-shell">
            <svg
                className="signal-chart"
                viewBox="0 0 1000 360"
                role="img"
                aria-label="Accelerometer X, Y, and Z traces"
            >
                {[<line
                    key={f"h-{line}"}
                    x1="0"
                    x2="1000"
                    y1={str(line * 60)}
                    y2={str(line * 60)}
                    className="grid-line"
                /> for line in range(7)]}
                {[<line
                    key={f"v-{line}"}
                    y1="0"
                    y2="360"
                    x1={str(line * 100)}
                    x2={str(line * 100)}
                    className="grid-line"
                /> for line in range(11)]}
                <polyline
                    points={axis_points(samples, "x", width, height)}
                    className="trace trace-x"
                />
                <polyline
                    points={axis_points(samples, "y", width, height)}
                    className="trace trace-y"
                />
                <polyline
                    points={axis_points(samples, "z", width, height)}
                    className="trace trace-z"
                />
            </svg>
            {len(samples) == 0 and <div className="chart-empty">
                Waiting for readings
            </div>}
        </div>;
    }

    def:pub ReadingTable(samples: list[dict]) -> JsxElement {
        recent = samples[-12:] if len(samples) > 12 else samples;
        return <div className="table-wrap">
            <table>
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>X</th>
                        <th>Y</th>
                        <th>Z</th>
                        <th>Label</th>
                    </tr>
                </thead>
                <tbody>
                    {[<tr key={str(sample.get("sample_id", index))}>
                        <td>{str(sample.get("captured_at_ms", "-"))}</td>
                        <td>{f"{float(sample.get('x', 0.0)):.3f}"}</td>
                        <td>{f"{float(sample.get('y', 0.0)):.3f}"}</td>
                        <td>{f"{float(sample.get('z', 0.0)):.3f}"}</td>
                        <td>{str(sample.get("label") or "unlabeled")}</td>
                    </tr> for (index, sample) in enumerate(recent)]}
                </tbody>
            </table>
        </div>;
    }

    def:pub app() -> JsxElement {
        has api_base: str = "";
        has api_key: str = "";
        has session_id: str = "training-001";
        has samples: list[dict] = [];
        has loading: bool = True;
        has status: str = "loading configuration";
        has error: str = "";
        has last_updated: str = "never";

        async def load_config() -> None {
            try {
                response = await fetch("/config.json", {"cache": "no-store"});
                if response.ok {
                    config = await response.json();
                    api_base = str(config.get("apiBaseUrl", "")).rstrip("/");
                    api_key = str(config.get("apiKey", ""));
                    session_id = str(config.get("sessionId", session_id));
                }
            } except Exception {
                status = "local fixture mode";
            }
        }

        async def fetch_samples() -> None {
            if not api_base {
                loading = False;
                status = "API not configured";
                return;
            }
            try {
                url = (
                    api_base
                    + "/api/samples?session_id="
                    + encodeURIComponent(session_id)
                );
                response = await fetch(url, {
                    "headers": {"X-Api-Key": api_key},
                    "cache": "no-store"
                });
                if not response.ok {
                    raise Exception(f"HTTP {response.status}");
                }
                payload = await response.json();
                samples = list(payload.get("samples", []));
                status = "live from DynamoDB";
                error = "";
                last_updated = new Date().toLocaleTimeString();
            } except Exception as caught {
                status = "API unavailable";
                error = str(caught);
            }
            loading = False;
        }

        async def initialize() -> None {
            await load_config();
            await fetch_samples();
        }

        useEffect(lambda {
            initialize();
            interval = setInterval(lambda { fetch_samples(); }, 2000);
            return lambda { clearInterval(interval); };
        }, []);

        duration = (
            int(samples[-1].get("captured_at_ms", 0))
            - int(samples[0].get("captured_at_ms", 0))
        ) / 1000.0 if len(samples) > 1 else 0.0;

        return <main className="shell">
            <header className="masthead">
                <div>
                    <p className="eyebrow">Wirejac Motion Lab / Capture 01</p>
                    <h1>Snatch detection dataset</h1>
                    <p className="lede">
                        MPU6050 acceleration experiments captured at the moment
                        an unlocked phone leaves the hand.
                    </p>
                </div>
                <div className="status-card">
                    <span className={"status-dot " + ("live" if not error else "error")}></span>
                    <div><small>Pipeline</small><strong>{status}</strong></div>
                </div>
            </header>

            <section className="controls">
                <label>
                    <span>Experiment session</span>
                    <input
                        value={session_id}
                        onChange={lambda event: ChangeEvent {
                            session_id = event.target.value;
                        }}
                        onKeyDown={lambda event: KeyboardEvent {
                            if event.key == "Enter" { fetch_samples(); }
                        }}
                    />
                </label>
                <button onClick={lambda { fetch_samples(); }} disabled={loading}>
                    {"Loading" if loading else "Load session"}
                </button>
                <span className="updated">Updated {last_updated}</span>
            </section>

            {error and <div className="error-banner">{error}</div>}

            <section className="metrics" aria-label="Collection summary">
                <article><strong>{len(samples)}</strong><span>readings</span></article>
                <article><strong>100 Hz</strong><span>sample rate</span></article>
                <article><strong>{f"{duration:.2f}s"}</strong><span>duration</span></article>
                <article><strong>{session_id}</strong><span>session</span></article>
            </section>

            <section className="chart-panel">
                <div className="panel-heading">
                    <div><p className="eyebrow">Acceleration</p><h2>Three-axis signal</h2></div>
                    <div className="legend">
                        <span className="x">X</span>
                        <span className="y">Y</span>
                        <span className="z">Z</span>
                    </div>
                </div>
                <SignalChart samples={samples} />
            </section>

            <section className="readings-panel">
                <div className="panel-heading">
                    <div><p className="eyebrow">Inspection</p><h2>Latest readings</h2></div>
                    <span className="count-badge">{len(samples)} total</span>
                </div>
                <ReadingTable samples={samples} />
            </section>
        </main>;
    }
}
