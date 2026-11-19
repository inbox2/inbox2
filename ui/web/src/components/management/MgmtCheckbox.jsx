import { forwardRef } from 'react';
import styles from './MgmtCheckbox.module.css';

/* The one checkbox box. A drop-in for a raw `<input type="checkbox">`: it is
 * only the box, so the caller's own <label> row keeps its layout. Inside
 * `.management` it wears the console palette; elsewhere every --m-* token
 * falls back to the app's control tokens (same arrangement as MgmtSelect). */
const MgmtCheckbox = forwardRef(function MgmtCheckbox({ className, ...props }, ref) {
  return <input ref={ref} type="checkbox" className={[styles.box, className].filter(Boolean).join(' ')} {...props} />;
});

export default MgmtCheckbox;
