/* Animate UI-style icons — Lucide icons animated with Motion (framer-motion).
   Per animate-ui.com/docs/icons: "Lucide Icons animated with Motion." Each node
   kind gets its own icon; it animates continuously while `active` (the node is
   "working") and on hover. Minimalist: thin strokes, currentColor. */
import React from "react";
import { motion } from "framer-motion";
import {
  Workflow,
  Server,
  Monitor,
  Cpu,
  Rocket,
  Activity,
} from "lucide-react";

type IconProps = { className?: string; active?: boolean; size?: number };

const PULSE = { scale: [1, 1.18, 1] };
const PULSE_T = { duration: 1.4, repeat: Infinity, ease: "easeInOut" };
const SPIN = { rotate: 360 };
const SPIN_T = { duration: 9, repeat: Infinity, ease: "linear" };

function Animated({
  Icon,
  anim,
  animT,
  className,
  active = false,
  size = 20,
}: IconProps & { Icon: React.ComponentType<any>; anim: any; animT: any }) {
  return (
    <motion.span
      className={className}
      style={{ display: "inline-flex" }}
      animate={active ? anim : { scale: 1, rotate: 0 }}
      transition={active ? animT : { duration: 0.2 }}
      whileHover={{ scale: 1.15 }}
    >
      <Icon size={size} strokeWidth={1.75} />
    </motion.span>
  );
}

export const CoordinatorIcon = (p: IconProps) => (
  <Animated {...p} Icon={Workflow} anim={SPIN} animT={SPIN_T} />
);
export const DeploymentIcon = (p: IconProps) => (
  <Animated {...p} Icon={Rocket} anim={PULSE} animT={PULSE_T} />
);
export const MonitoringIcon = (p: IconProps) => (
  <Animated {...p} Icon={Activity} anim={PULSE} animT={PULSE_T} />
);

const WORKER_ICONS: Record<string, React.ComponentType<any>> = {
  server: Server,
  client: Monitor,
  device: Cpu,
};
export const WorkerIcon = (p: IconProps & { kind?: string }) => {
  const Icon = WORKER_ICONS[(p.kind ?? "").toLowerCase()] ?? Server;
  return <Animated {...p} Icon={Icon} anim={PULSE} animT={PULSE_T} />;
};

// touch: trigger jac watcher copy
