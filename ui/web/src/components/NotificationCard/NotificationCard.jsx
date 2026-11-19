// The one notification card (docs/Notifications.md), as building blocks: the
// in-app popup (NewMessagePopup) and the desktop notification window
// (NotificationPage) compose these and add only what differs — the page its
// swipe-to-dismiss pointer handlers and OTP row, the popup its collapsed stack,
// merged card and triage dropdown.
import Icon from '../Icon';
import { applyRailColors } from '../../stores/notificationStore';
import styles from './NotificationCard.module.css';

// Callers that need a shared class (`snippet`, `detail`) import the module directly.

function cx(...parts) { return parts.filter(Boolean).join(' '); }

/** Card shell: glass surface + rail colours + the countdown bar. */
export default function NotificationCard({
  eventColor, dismissMs, collapsed = false, zone = false, className, cardRef, children, ...rest
}) {
  return (
    <div
      {...rest}
      className={cx(styles.card, zone && styles.zone, collapsed && styles.collapsed, className)}
      data-collapsed={collapsed || undefined}
      ref={(el) => {
        if (cardRef) cardRef.current = el;
        applyRailColors(el, eventColor, dismissMs);
      }}
    >
      <div className={styles.body}>{children}</div>
      <div className={cx(styles.countdown, dismissMs === 0 && styles.countdownStatic)} />
    </div>
  );
}

/** Event-type row: glyph, label, optional time, dismiss ×. */
export function CardHead({ glyph, label, time, onDismiss }) {
  return (
    <div className={styles.head}>
      {glyph}
      <span className={styles.eventLabel}>{label}</span>
      {time != null && <span className={styles.eventTime}>{time}</span>}
      <button type="button" className={styles.dismissBtn} onClick={onDismiss} aria-label="Dismiss">
        <Icon name="xmark" size={11} />
      </button>
    </div>
  );
}

/** Subject line — always visible. */
export function CardContext({ children }) {
  return <div className={styles.context}>{children}</div>;
}

/** Sender line (+ optional site icon) with the snippet / OTP row as children. */
export function CardDetail({ siteIcon, meta, className, children }) {
  return (
    <div className={cx(styles.detail, className)}>
      {siteIcon && <img className={styles.siteIcon} src={siteIcon} alt="" width={40} height={40} />}
      <div className={styles.detailText}>
        <div className={styles.meta}>{meta}</div>
        {children}
      </div>
    </div>
  );
}

export function CardActions({ className, children }) {
  return <div className={cx(styles.actions, className)}>{children}</div>;
}

export function ActionButton({ icon, className, children, ...props }) {
  return (
    <button type="button" className={cx(styles.actionBtn, className)} {...props}>
      <Icon name={icon} size={12} />
      {children}
    </button>
  );
}
