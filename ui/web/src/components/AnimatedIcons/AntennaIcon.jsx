import { forwardRef, useImperativeHandle } from 'react';
import { motion, useAnimate } from 'motion/react';

/* A broadcasting antenna / carrier-signal icon: a central node with two pairs of
 * arcs radiating outward. Unlike the hover-triggered icons in this folder, this
 * one AUTO-LOOPS (it lives in a passive status banner with no hover affordance) —
 * the inner then outer waves pulse outward, reading as "waiting for signal" for a
 * domain whose MX records aren't live yet. startAnimation/stopAnimation are kept
 * for parity with the family (a parent can still drive it on hover). */
const WAVE = (delay) => ({
  opacity: [0.25, 1, 0.25],
  transition: { duration: 1.6, ease: 'easeInOut', repeat: Infinity, delay },
});

const AntennaIcon = forwardRef(({ size = 24, color = 'currentColor', strokeWidth = 2, className = '' }, ref) => {
  const [scope, animate] = useAnimate();

  // The arcs already loop declaratively; start/stop give a quick emphasis pulse
  // on the central node when a parent drives the ref (kept for family parity).
  const start = () => animate('.antenna-core', { scale: [1, 1.4, 1] }, { duration: 0.5, ease: 'easeOut' });
  const stop = () => animate('.antenna-core', { scale: 1 }, { duration: 0.2 });
  useImperativeHandle(ref, () => ({ startAnimation: start, stopAnimation: stop }));

  return (
    <motion.svg
      ref={scope}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke={color}
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {/* central node */}
      <motion.circle className="antenna-core" cx="12" cy="12" r="1.6" fill={color} stroke="none" />
      {/* inner waves */}
      <motion.path d="M9.17 9.17a4 4 0 0 0 0 5.66" animate={WAVE(0)} />
      <motion.path d="M14.83 9.17a4 4 0 0 1 0 5.66" animate={WAVE(0)} />
      {/* outer waves (staggered) */}
      <motion.path d="M6.34 6.34a8 8 0 0 0 0 11.32" animate={WAVE(0.4)} />
      <motion.path d="M17.66 6.34a8 8 0 0 1 0 11.32" animate={WAVE(0.4)} />
    </motion.svg>
  );
});

AntennaIcon.displayName = 'AntennaIcon';
export default AntennaIcon;
