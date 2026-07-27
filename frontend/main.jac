"""frontend - Entry Point.

Combines server-side endpoints with the client-side UI.
"""

import from endpoints {
    get_graph_snapshot,
    get_hardware_job,
    get_request_events,
    get_request_history,
    ping,
    resolve_followup_hardware_approval,
    resolve_hardware_approval,
    submit_build,
    submit_frontend_followup,
    submit_hardware_followup,
    submit_project_followup
}

# Client-side UI
cl {
    import from .frontend { app as ClientApp }
    import ".styles.global.css";
    import ".styles.brand.css";
    import "@xyflow/react/dist/style.css";

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
