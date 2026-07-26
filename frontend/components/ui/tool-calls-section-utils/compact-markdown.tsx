// Minimal compact renderer for tool inputs/outputs (no react-markdown dep).
// Objects render as pretty key/value lines; strings render as text. Keeps the
// tool-call detail view tidy and on-theme.
import type { ReactNode } from "react";

export function CompactMarkdown({ content }: { content: unknown }): ReactNode {
  if (content == null) return null;

  if (typeof content === "string") {
    return <span className="text-muted-foreground whitespace-pre-wrap break-words">{content}</span>;
  }

  if (typeof content === "object") {
    const entries = Object.entries(content as Record<string, unknown>);
    return (
      <div className="flex flex-col gap-1">
        {entries.map(([k, v]) => (
          <div key={k} className="flex gap-2">
            <span className="text-foreground/70 font-medium shrink-0">{k}</span>
            <span className="text-muted-foreground break-words">
              {typeof v === "object" ? JSON.stringify(v) : String(v)}
            </span>
          </div>
        ))}
      </div>
    );
  }

  return <span className="text-muted-foreground">{String(content)}</span>;
}

// touch
