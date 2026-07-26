/* Animate UI-style icons — Lucide icons animated with CSS (not framer-motion).
   CSS keyframes (wj-icon-spin / wj-icon-pulse, defined in brand.css) run on the
   element independently of React re-renders, so they play smoothly even though
   the dashboard re-renders every 200ms on the run clock. Each node kind gets
   its own icon; it animates while `active` (the node is "working"). */
import React from "react";
import { Workflow, Server, Monitor, Cpu, Rocket, Activity } from "lucide-react";

type IconProps = { className?: string; active?: boolean; size?: number };

function Animated({
  Icon,
  mode,
  className,
  active = false,
  size = 20,
}: IconProps & { Icon: React.ComponentType<any>; mode: "spin" | "pulse" }) {
  const anim = active ? (mode === "spin" ? "wj-icon-spin" : "wj-icon-pulse") : "";
  return (
    <span className={[className, "wj-icon", anim].filter(Boolean).join(" ")}>
      <Icon size={size} strokeWidth={1.75} />
    </span>
  );
}

export const CoordinatorIcon = (p: IconProps) => <Animated {...p} Icon={Workflow} mode="spin" />;
export const DeploymentIcon = (p: IconProps) => <Animated {...p} Icon={Rocket} mode="pulse" />;
export const MonitoringIcon = (p: IconProps) => <Animated {...p} Icon={Activity} mode="pulse" />;

const WORKER_ICONS: Record<string, React.ComponentType<any>> = {
  server: Server,
  client: Monitor,
  device: Cpu,
};
export const WorkerIcon = (p: IconProps & { kind?: string }) => {
  const Icon = WORKER_ICONS[(p.kind ?? "").toLowerCase()] ?? Server;
  return <Animated {...p} Icon={Icon} mode="pulse" />;
};

// touch
