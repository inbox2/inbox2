import { forwardRef, useImperativeHandle, useCallback } from 'react';
import { motion, useAnimate } from 'motion/react';
import styles from './AnimatedIcons.module.css';

const UserPlusIcon = forwardRef(({ size = 24, color = 'currentColor', strokeWidth = 2, className = '' }, ref) => {
  const [scope, animate] = useAnimate();

  const start = useCallback(async () => {
    animate('.user-avatar', { scale: 1.05, y: -1 }, { duration: 0.25, ease: 'easeOut' });
    animate('.plus-sign', { scale: 1.15, rotate: 90 }, { duration: 0.3, ease: 'easeOut' });
  }, [animate]);

  const stop = useCallback(async () => {
    animate('.user-avatar', { scale: 1, y: 0 }, { duration: 0.2, ease: 'easeInOut' });
    animate('.plus-sign', { scale: 1, rotate: 0 }, { duration: 0.25, ease: 'easeInOut' });
  }, [animate]);

  useImperativeHandle(ref, () => ({ startAnimation: start, stopAnimation: stop }));

  return (
    <motion.svg ref={scope} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" className={className} onHoverStart={start} onHoverEnd={stop}>
      <path stroke="none" d="M0 0h24v24H0z" fill="none" />
      <motion.g className={`user-avatar ${styles.userAvatar}`}>
        <path d="M8 7a4 4 0 1 0 8 0a4 4 0 0 0 -8 0" />
        <path d="M6 21v-2a4 4 0 0 1 4 -4h4" />
      </motion.g>
      <motion.g className={`plus-sign ${styles.plusSign}`}>
        <path d="M16 19h6" />
        <path d="M19 16v6" />
      </motion.g>
    </motion.svg>
  );
});

UserPlusIcon.displayName = 'UserPlusIcon';
export default UserPlusIcon;
