// Tool-name formatting + per-category icon resolution for tool-calls-section.
import type { ReactNode } from "react";
import { HugeiconsIcon } from "@hugeicons/react";
import {
  AiBrain01Icon,
  SourceCodeIcon,
  RocketIcon,
  Loading03Icon,
  PulseIcon,
  File01Icon,
  ComputerIcon,
  SmartPhone01Icon,
  ComputerTerminal01Icon,
  ToolsIcon,
} from "@hugeicons/core-free-icons";

// "send_email" -> "Send Email"
export function formatToolName(name: string): string {
  return (name || "")
    .replace(/[_-]+/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

const CATEGORY_ICON: Record<string, any> = {
  planning: AiBrain01Icon,
  coordinator: AiBrain01Icon,
  codegen: SourceCodeIcon,
  server: ComputerTerminal01Icon,
  client: SmartPhone01Icon,
  device: ComputerIcon,
  compile: Loading03Icon,
  deploy: RocketIcon,
  deployment: RocketIcon,
  monitor: PulseIcon,
  monitoring: PulseIcon,
  file: File01Icon,
  executor: ComputerTerminal01Icon,
};

// Returns an icon node for a tool category. If an explicit icon URL is given,
// render it as an image; otherwise map the category to a Hugeicon.
export function getToolCategoryIcon(
  category: string,
  size: { width: number; height: number },
  iconUrl?: string,
): ReactNode | null {
  if (iconUrl) {
    return (
      <img
        src={iconUrl}
        alt={category}
        style={{ width: size.width, height: size.height, borderRadius: 6 }}
      />
    );
  }
  const icon = CATEGORY_ICON[(category || "").toLowerCase()] ?? ToolsIcon;
  return (
    <div
      className="flex items-center justify-center rounded-lg bg-muted text-muted-foreground"
      style={{ width: size.width, height: size.height }}
    >
      <HugeiconsIcon icon={icon} size={Math.round(size.width * 0.62)} strokeWidth={1.8} />
    </div>
  );
}

// touch
