import { useEffect, useId, useRef, useState } from 'react';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import styles from './MoveEventDialog.module.css';

const SCOPES = [
  { value: 'this', label: 'This event', hint: 'Only this one changes' },
  { value: 'following', label: 'This and following events', hint: 'Earlier events stay as they were' },
  { value: 'all', label: 'All events', hint: 'Every event in the series changes the same way' },
];

/**
 * Asked after an event is dragged or resized, Google-Calendar style: for a
 * repeating event, move this one or the whole series; for an event with guests,
 * mail them the change or not. Stays open while the move saves, so a second
 * drag can't race it; a refused move comes back here with the reason.
 *
 * Props:
 *   channel     — { type, iconUrl } of the account the event lives on
 *   title       — the event's title
 *   when        — the new time, already formatted
 *   resized     — only the length changed (a resize, not a drag)
 *   recurring   — the event repeats; offer the scope choice
 *   allAllowed  — "All events" is possible (false when it moved to another day)
 *   hasGuests   — the organizer has guests to tell
 *   canSkipMail — the source can save without mailing them (Graph always mails)
 *   saving      — the move is in flight
 *   error       — why the last attempt failed; the buttons then retry it
 *   scopes      — which scope choices to offer (default this / all — a drag)
 *   editing     — asked from the editor's Save, not a drag: "Save" wording
 *   onConfirm   — ({ scope, notify }) => void
 *   onCancel    — () => void; the event goes back where it was
 */
export default function MoveEventDialog({
  open, channel, title, when, resized, recurring, allAllowed, hasGuests, canSkipMail, saving, error, onConfirm, onCancel,
  scopes = ['this', 'all'], editing = false,
}) {
  const [scope, setScope] = useState(scopes[0]);
  const titleId = useId();
  // While saving, every other control is disabled; the main button stays
  // focusable (aria-disabled) and takes focus, so focus never leaves the
  // dialog and the "Saving…" label is announced.
  const primaryRef = useRef(null);
  useEffect(() => { if (saving) primaryRef.current?.focus(); }, [saving]);
  const confirm = (notify) => onConfirm({ scope: allAllowed ? scope : scopes[0], notify });
  const verb = resized || editing ? 'Save' : 'Move';
  const sendLabel = hasGuests ? (canSkipMail ? 'Send' : `${verb} and send`) : verb;
  const heading = editing
    ? (recurring ? 'Save recurring event' : 'Save event')
    : resized
      ? (recurring ? 'Change length of recurring event' : 'Change event length')
      : (recurring ? 'Move recurring event' : 'Move event');

  return (
    <Modal open={open} onClose={() => { if (!saving) onCancel(); }} showClose={false} titleId={titleId} className={styles.dialog}>
      <div className={styles.header}>
        <ProviderIcon type={channel?.type} iconUrl={channel?.iconUrl} size={18} />
        <h3 id={titleId} className={styles.title}>{heading}</h3>
      </div>

      <p className={styles.event}>
        <span className={styles.eventTitle}>{title || '(No title)'}</span>
        <span className={styles.when}>{when}</span>
      </p>

      {recurring && (
        allAllowed ? (
          <fieldset className={styles.scope} disabled={saving}>
            <legend className={styles.legend}>Which events</legend>
            {SCOPES.filter(opt => scopes.includes(opt.value)).map(opt => (
              <label key={opt.value} className={styles.option}>
                <input
                  type="radio"
                  name={`${titleId}-scope`}
                  value={opt.value}
                  checked={scope === opt.value}
                  onChange={() => setScope(opt.value)}
                  className={styles.radio}
                />
                <span className={styles.optionText}>
                  {opt.label}
                  <span className={styles.optionHint}>{opt.hint}</span>
                </span>
              </label>
            ))}
          </fieldset>
        ) : (
          <p className={styles.message}>Only this event changes. Moving every event to another day isn&apos;t supported yet.</p>
        )
      )}

      {hasGuests && (
        <p className={styles.message}>
          {canSkipMail
            ? 'Send an update to the guests?'
            : 'Office 365 emails your guests about this change. It can’t be changed without telling them.'}
        </p>
      )}

      {error && <p className={styles.error} role="alert">Couldn&apos;t save it: {error}</p>}

      <div className={styles.actions}>
        <Button variant="secondary" className={styles.btn} onClick={onCancel} disabled={saving}>Cancel</Button>
        {hasGuests && canSkipMail && (
          <Button variant="secondary" className={styles.btn} onClick={() => confirm(false)} disabled={saving}>Don&apos;t send</Button>
        )}
        <Button
          ref={primaryRef}
          className={styles.btn}
          onClick={() => { if (!saving) confirm(true); }}
          aria-disabled={saving || undefined}
          aria-live="polite"
          autoFocus
        >
          {saving ? 'Saving…' : error && !hasGuests ? 'Try again' : sendLabel}
        </Button>
      </div>
    </Modal>
  );
}
