import { Link } from "react-router";
import styles from "./Button.module.css";

/**
 * Pill button. variant: accent | offset | ink | glass | glassink.
 * Renders <Link> for internal `to`, <a> for `href`, <button> otherwise.
 * Hover = press (scale down), active = press harder.
 */
export default function Button({ variant = "accent", size = "md", to, href, children, className = "", ...rest }) {
  const cls = [styles.btn, styles[variant], styles[size], className].join(" ");
  if (to) return <Link to={to} className={cls} {...rest}>{children}</Link>;
  if (href) {
    const ext = /^https?:/.test(href) ? { target: "_blank", rel: "noopener" } : {};
    return <a href={href} className={cls} {...ext} {...rest}>{children}</a>;
  }
  return <button type="button" className={cls} {...rest}>{children}</button>;
}
