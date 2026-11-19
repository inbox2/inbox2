import styles from './MgmtButton.module.css';

/* Management-layer button — the single console/auth button (homepage vibe).
 * variant: 'primary' (steel-blue fill) | 'glass' (outline → blue on hover)
 *          | 'dark' (white fill) | 'ghost' (subtle inset) | 'danger'.
 * size: 'md' (default) | 'sm' (compact, for inline/table actions).
 * Pass `block` to span the full width (forms). This is the ONE console button —
 * new console/admin buttons must use it (no bespoke .someBtn classes). */
export default function MgmtButton({
  as: Component = 'button',
  variant = 'primary',
  size = 'md',
  block = false,
  type = 'button',
  className,
  children,
  ...rest
}) {
  const cls = [
    styles.btn,
    styles[variant] || styles.primary,
    size === 'sm' ? styles.sm : '',
    block ? styles.block : '',
    className,
  ].filter(Boolean).join(' ');
  // `type` only applies to real <button>s; anchors/Links must not receive it.
  const typeProp = Component === 'button' ? { type } : {};
  return (
    <Component className={cls} {...typeProp} {...rest}>
      {children}
    </Component>
  );
}
