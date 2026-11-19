import { forwardRef, useImperativeHandle, useRef } from 'react';
import { motion, useAnimate } from 'motion/react';
import styles from './AnimatedIcons.module.css';

const AlarmClockIcon = forwardRef(({ size = 24, color = 'currentColor', strokeWidth = 2, className = '' }, ref) => {
  const [scope, animate] = useAnimate();
  const controls = useRef([]);

  const start = async () => {
    controls.current.forEach(c => c.stop());
    controls.current = [];
    controls.current.push(
      animate('.clock', { y: -1.5, x: [-1, 1, -1, 1, -1, 0] }, { y: { duration: 0.2, type: 'spring', stiffness: 200, damping: 25 }, x: { duration: 0.3, repeat: Infinity, ease: 'linear' } }),
      animate('.bells', { y: -2.5, x: [-2, 2, -2, 2, -2, 0] }, { y: { duration: 0.2, type: 'spring', stiffness: 200, damping: 25 }, x: { duration: 0.3, repeat: Infinity, ease: 'linear' } })
    );
  };

  const stop = () => {
    controls.current.forEach(c => c.stop());
    controls.current = [];
    animate('.clock', { y: 0, x: 0 }, { duration: 0.4 });
    animate('.bells', { y: 0, x: 0 }, { duration: 0.4 });
  };

  useImperativeHandle(ref, () => ({ startAnimation: start, stopAnimation: stop }));

  return (
    <motion.svg ref={scope} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" className={className} onHoverStart={start} onHoverEnd={stop}>
      <motion.circle className="clock" cx="12" cy="13" r="8" />
      <motion.path className={`bells ${styles.bellLeft}`} d="M5 3 2 6" />
      <motion.path className={`bells ${styles.bellRight}`} d="m22 6-3-3" />
      <motion.path className="clock" d="M6.38 18.7 4 21" />
      <motion.path className="clock" d="M17.64 18.67 20 21" />
      <path d="M12 10v6" />
      <path d="M9 13h6" />
    </motion.svg>
  );
});

AlarmClockIcon.displayName = 'AlarmClockIcon';
export default AlarmClockIcon;
