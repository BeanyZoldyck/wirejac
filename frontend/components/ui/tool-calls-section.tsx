"use client";

import type { ReactNode } from "react";
import { useMemo, useState } from "react";

import { HugeiconsIcon, ArrowDown01Icon, ToolsIcon } from "./tool-calls-section-utils/icons";
import { formatToolName, getToolCategoryIcon } from "./tool-calls-section-utils/tool-icons";
import { CompactMarkdown } from "./tool-calls-section-utils/compact-markdown";

const cn = (...classes: (string | undefined | null | false)[]) => classes.filter(Boolean).join(" ");

// ============================================================================
// Types
// ============================================================================

export interface ToolCallEntry {
  tool_name: string;
  tool_category: string;
  message?: string;
  show_category?: boolean;
  tool_call_id?: string;
  inputs?: Record<string, unknown>;
  output?: string;
  icon_url?: string;
  integration_name?: string;
}

export interface IntegrationInfo {
  iconUrl?: string;
  name?: string;
}

export interface ToolCallsSectionProps {
  toolCalls: ToolCallEntry[];
  integrations?: Map<string, IntegrationInfo>;
  maxIconsToShow?: number;
  defaultExpanded?: boolean;
  className?: string;
  iconSize?: number;
  renderIcon?: (call: ToolCallEntry, size: number) => ReactNode;
  renderContent?: (content: unknown) => ReactNode;
}

// ============================================================================
// Helpers
// ============================================================================

function ChevronIcon({ isExpanded, size = 18, className = "" }: { isExpanded: boolean; size?: number; className?: string }) {
  return (
    <HugeiconsIcon
      icon={ArrowDown01Icon}
      size={size}
      className={cn("transition-transform duration-200", isExpanded && "rotate-180", className)}
    />
  );
}

// ============================================================================
// Main Component
// ============================================================================

export function ToolCallsSection({
  toolCalls,
  integrations,
  maxIconsToShow = 10,
  defaultExpanded = false,
  className,
  iconSize = 21,
  renderIcon,
  renderContent,
}: ToolCallsSectionProps) {
  const [isExpanded, setIsExpanded] = useState(defaultExpanded);
  const [expandedCalls, setExpandedCalls] = useState<Set<number>>(new Set());

  const integrationLookup = useMemo(() => integrations ?? new Map<string, IntegrationInfo>(), [integrations]);

  const getIconUrl = (call: ToolCallEntry): string | undefined =>
    call.icon_url ?? integrationLookup.get(call.tool_category)?.iconUrl;
  const getIntegrationName = (call: ToolCallEntry): string | undefined =>
    call.integration_name ?? integrationLookup.get(call.tool_category)?.name;

  const toggleCallExpansion = (index: number) => {
    setExpandedCalls((prev) => {
      const next = new Set(prev);
      if (next.has(index)) next.delete(index);
      else next.add(index);
      return next;
    });
  };

  if (toolCalls.length === 0) return null;

  const defaultRenderIcon = (call: ToolCallEntry, size: number) => {
    const icon = getToolCategoryIcon(call.tool_category || "general", { width: size, height: size }, getIconUrl(call));
    return (
      icon || (
        <div className="p-1 min-w-8 min-h-8 bg-muted rounded-lg text-muted-foreground">
          <HugeiconsIcon icon={ToolsIcon} size={size} />
        </div>
      )
    );
  };
  const iconRenderer = renderIcon || defaultRenderIcon;

  const defaultRenderContent = (content: unknown) => <CompactMarkdown content={content} />;
  const contentRenderer = renderContent || defaultRenderContent;

  const renderStackedIcons = () => {
    const seen = new Set<string>();
    const uniqueIcons = toolCalls.filter((call) => {
      const c = call.tool_category || "general";
      if (seen.has(c)) return false;
      seen.add(c);
      return true;
    });
    const displayIcons = uniqueIcons.slice(0, maxIconsToShow);
    return (
      <div className="flex min-h-8 items-center -space-x-2">
        {displayIcons.map((call, index) => (
          <div
            key={`${call.tool_name}-${index}`}
            className="relative flex min-w-8 items-center justify-center"
            style={{
              rotate: displayIcons.length > 1 ? (index % 2 === 0 ? "8deg" : "-8deg") : "0deg",
              zIndex: index,
            }}
          >
            {iconRenderer(call, iconSize)}
          </div>
        ))}
        {uniqueIcons.length > maxIconsToShow && (
          <div className="z-0 flex size-7 min-h-7 min-w-7 items-center justify-center rounded-lg bg-muted text-xs text-muted-foreground font-normal">
            +{uniqueIcons.length - maxIconsToShow}
          </div>
        )}
      </div>
    );
  };

  return (
    <div className={cn("w-fit max-w-[35rem]", className)}>
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="flex items-center gap-2 hover:text-foreground text-muted-foreground cursor-pointer py-2"
      >
        {renderStackedIcons()}
        <span className="text-xs font-medium transition-all duration-200">
          Used {toolCalls.length} tool{toolCalls.length > 1 ? "s" : ""}
        </span>
        <ChevronIcon isExpanded={isExpanded} />
      </button>

      <div className={cn("overflow-hidden transition-all duration-200", isExpanded ? "max-h-[2000px] opacity-100" : "max-h-0 opacity-0")}>
        <div className="space-y-0 pt-1">
          {toolCalls.map((call, index) => {
            const hasCategoryText = call.show_category !== false && call.tool_category && call.tool_category !== "unknown";
            const hasDetails = call.inputs || call.output;
            const isCallExpanded = expandedCalls.has(index);
            return (
              <div key={`${call.tool_name}-step-${index}`} className="flex items-stretch gap-2">
                <div className="flex flex-col items-center self-stretch">
                  <div className="min-h-8 min-w-8 flex items-center justify-center shrink-0">{iconRenderer(call, iconSize)}</div>
                  {index < toolCalls.length - 1 && <div className="w-px flex-1 bg-border min-h-4" />}
                </div>
                <div className="flex-1 min-w-0">
                  <button
                    type="button"
                    className={cn("flex items-center gap-1 group/parent", hasDetails ? "cursor-pointer" : "", !hasCategoryText ? "pt-2" : "")}
                    onClick={() => hasDetails && toggleCallExpansion(index)}
                  >
                    <p className={cn("text-xs text-foreground/80 font-medium", hasDetails && "group-hover/parent:text-foreground")}>
                      {call.message || formatToolName(call.tool_name)}
                    </p>
                    {hasDetails && <ChevronIcon isExpanded={isCallExpanded} size={14} />}
                  </button>

                  {hasCategoryText && (
                    <p className="text-[11px] text-muted-foreground capitalize">
                      {getIntegrationName(call) ||
                        call.tool_category.replace(/_/g, " ").split(" ").map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(" ")}
                    </p>
                  )}

                  {isCallExpanded && hasDetails && (
                    <div className="mt-2 space-y-2 text-[11px] bg-muted rounded-xl p-3 mb-3 w-fit">
                      {call.inputs && Object.keys(call.inputs).length > 0 && (
                        <div className="flex flex-col">
                          <span className="text-muted-foreground font-medium mb-1">Input</span>
                          {contentRenderer(call.inputs)}
                        </div>
                      )}
                      {call.output && (
                        <div className="flex flex-col">
                          <span className="text-muted-foreground font-medium mb-1">Output</span>
                          {contentRenderer(call.output)}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

export default ToolCallsSection;

// touch
