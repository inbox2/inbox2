import { forwardRef, useImperativeHandle } from 'react';
import { useAnimate } from 'motion/react';
import Icon from '../Icon';

/* A space's own SF Symbol, animated on demand — the empty-state focal point in
 * treemap cells, echoing the Eisenhower grid's hover-animated quadrant icons.
 * Generic over any space icon (canonical or custom), so there's no per-slug
 * icon set to maintain. The parent cell calls startAnimation/stopAnimation on
 * hover via the forwarded ref. */
const AnimatedSpaceIcon = forwardRef(({ name, size = 40, className = '' }, ref) => {
  const [scope, animate] = useAnimate();

  const start = () => {
    animate(
      scope.current,
      { y: [0, -6, 0], rotate: [0, -7, 6, 0], scale: [1, 1.1, 1] },
      { duration: 0.7, ease: 'easeOut' },
    );
  };
  const stop = () => {
    animate(scope.current, { y: 0, rotate: 0, scale: 1 }, { duration: 0.2, ease: 'easeOut' });
  };

  useImperativeHandle(ref, () => ({ startAnimation: start, stopAnimation: stop }));

  return (
    <span ref={scope} className={className}>
      <Icon name={name} size={size} />
    </span>
  );
});

AnimatedSpaceIcon.displayName = 'AnimatedSpaceIcon';
export default AnimatedSpaceIcon;
