"""Single shared "working" loader (Phase 4).

One tasteful CSS-animation spinner in the spirit of loaders.wtf, reused across
every node in the `working` state. A small ~18px ring that borrows the current
text color (`border-primary` where placed on a node), driven entirely by the
scoped `Loader.style.css` annex (paired by base name -- do NOT import it; the
compiler injects + scopes the class, keyframe names stay global).
"""

# ---- Loader -----------------------------------------------------------------

# A minimal spinning ring. `wj-loader` is the scoped class (from the annex);
# `border-primary` is a Tailwind semantic token that passes through untouched
# and tints the ring with the accent color.
def:pub Loader() -> JsxElement {
    return <span
        className="wj-loader border-primary"
        role="status"
        aria-label="working"
    ></span>;
}
