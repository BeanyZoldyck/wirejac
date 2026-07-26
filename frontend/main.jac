"""frontend - Entry Point.

Combines server-side endpoints with the client-side UI.
"""

import from endpoints { ping }

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
