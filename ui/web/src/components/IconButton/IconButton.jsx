import { forwardRef, useRef, useEffect, useImperativeHandle } from 'react';
import Icon from '../Icon';
import styles from './IconButton.module.css';

/**
 * Square, ghost icon button — the shared "× / edit / archive" affordance.
 *
 * Encodes the house treatment once: flex-centered, square, subtle border over
 * an overlay surface, hover lift, and a `:focus-visible` glow ring (all via
 * tokens). Renders an `<Icon>` by name.
 *
 * Props:
 *   icon       — SF Symbol name (required)
 *   iconSize   — px size of the glyph (default 14)
 *   size       — box size: 'sm' (24px) | 'md' (28px) | number (default 'md')
 *   variant    — 'default' | 'danger' (danger reddens on hover)
 *   aria-label — accessible label (required; falls back to title)
 *   className  — extra class(es) merged onto the button
 *   ...props   — forwarded to the underlying <button> (onClick, disabled, title…)
 */
const SIZE_PX = { sm: 24, md: 28 };

const IconButton = forwardRef(function IconButton(
  { icon, iconSize = 14, size = 'md', variant = 'default', className, ...props },
  ref,
) {
  const innerRef = useRef(null);
  useImperativeHandle(ref, () => innerRef.current);

  const px = typeof size === 'number' ? size : (SIZE_PX[size] ?? SIZE_PX.md);

  useEffect(() => {
    if (innerRef.current) innerRef.current.style.setProperty('--icon-button-size', `${px}px`);
  }, [px]);

  const classes = [
    styles.button,
    variant === 'danger' ? styles.danger : '',
    className || '',
  ].filter(Boolean).join(' ');

  return (
    <button ref={innerRef} type="button" className={classes} {...props}>
      <Icon name={icon} size={iconSize} />
    </button>
  );
});

export default IconButton;
