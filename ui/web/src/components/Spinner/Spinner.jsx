import { useRef, useEffect } from 'react';
import Icon from '../Icon';
import styles from './Spinner.module.css';

/**
 * The single spinning indicator for the app. Owns the one `@keyframes spin`.
 *
 * Two visual modes:
 *  - ring (default): a rotating border ring (the dominant inline-loading look).
 *  - icon: rotates a provided SF Symbol via `<Icon>` (sync/refresh affordances).
 *
 * Sizing: `size` accepts a token name ('sm' | 'md') or a number (px). Numeric
 * sizes are applied via a CSS custom property — no inline style. Color comes
 * from the `color` prop (any CSS color / token) and likewise flows through a
 * custom property, defaulting to --text-tertiary.
 */
const SIZE_PX = { sm: 10, md: 16 };

export default function Spinner({
  size = 'sm',
  color,
  variant = 'ring',
  icon = 'arrow.triangle.2.circlepath',
  className,
  label = 'Loading',
}) {
  const ref = useRef(null);
  const px = typeof size === 'number' ? size : (SIZE_PX[size] ?? SIZE_PX.sm);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.setProperty('--spinner-size', `${px}px`);
    if (color) el.style.setProperty('--spinner-color', color);
  }, [px, color]);

  const classes = [
    variant === 'icon' ? styles.icon : styles.ring,
    className || '',
  ].filter(Boolean).join(' ');

  return (
    <span
      ref={ref}
      className={classes}
      role="status"
      aria-label={label}
    >
      {variant === 'icon' && <Icon name={icon} size={px} />}
    </span>
  );
}
