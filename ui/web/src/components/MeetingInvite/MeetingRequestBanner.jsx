import { useState, useContext } from 'react'
import Button from '../Button/Button'
import Icon from '../Icon'
import api from '../../lib/api'
import { isRealOrgId } from '../../lib/org'
import { AuthContext } from '../../hooks/AuthProvider'
import log from '../../lib/log'
import styles from './MeetingInvite.module.css'

// Meet-link meeting request banner (docs/Calendar.md) — the request variant of
// the invite banner. Same layout and muscle memory as MeetingInvite, different
// wiring: nothing is on the calendar yet; Accept creates the event (you as
// organizer, the visitor pre-accepted) and mails them a real ICS invite,
// Decline mails a polite no with an optional reason. Decisions are final —
// the visitor was already emailed — so there is no "Change" affordance.
const STATUS_LABEL = {
  accepted: "You accepted. It's on your calendar.",
  declined: 'You declined',
  expired: 'This request expired before you answered.',
}

const CONFERENCE_HINT = {
  meet: 'Accepting adds a Google Meet link.',
  teams: 'Accepting adds a Teams link.',
}

function fmtTime(date, timeZone) {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit', timeZone })
}

export default function MeetingRequestBanner({ message, orgId }) {
  const request = message?.meeting_request
  // Only the person being booked can answer — the whole org pool can see the
  // thread, so everyone else gets a read-only "waiting" row instead of
  // Accept/Decline buttons that would 403. Context directly, not useAuth():
  // this renders inside message cards Storybook mounts provider-less.
  const auth = useContext(AuthContext)
  const myAddress = auth?.organizations?.find((o) => o.id === orgId)?.mailbox?.toLowerCase()
  const inviteeEmail = request?.invitee_email?.toLowerCase()
  const forSomeoneElse = !!inviteeEmail && !!myAddress && inviteeEmail !== myAddress
  const [status, setStatus] = useState(request?.status !== 'pending' ? request?.status : null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  const [declining, setDeclining] = useState(false)
  const [reason, setReason] = useState('')

  if (!request) return null

  const start = new Date(request.start)
  const end = new Date(request.end)
  const minutes = Math.round((end - start) / 60000)
  const when = `${start.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })} · ${fmtTime(start)} – ${fmtTime(end)}`

  // The visitor's own clock, when it isn't the viewer's.
  const viewerTz = Intl.DateTimeFormat().resolvedOptions().timeZone
  const visitorTz = request.visitor_timezone
  const theirTime = visitorTz && visitorTz !== viewerTz
    ? `Their time: ${fmtTime(start, visitorTz)} – ${fmtTime(end, visitorTz)} (${visitorTz.split('/').pop().replace(/_/g, ' ')})`
    : null

  async function accept() {
    if (!isRealOrgId(orgId)) return
    setBusy('accept')
    setError(null)
    try {
      const res = await api.acceptMeetingRequest(orgId, request.key)
      setStatus('accepted')
      if (res?.conflict) setNotice('This now overlaps another event on your calendar.')
      else if (res?.conference_error) setNotice("We couldn't make the meeting link. You can add one to the event.")
    } catch (e) {
      log.warn('[MeetingRequestBanner] accept failed', e)
      setError(e?.message || 'Couldn’t accept. Try again.')
    } finally {
      setBusy(null)
    }
  }

  async function decline() {
    if (!isRealOrgId(orgId)) return
    setBusy('decline')
    setError(null)
    try {
      await api.declineMeetingRequest(orgId, request.key, reason.trim() || undefined)
      setStatus('declined')
      setDeclining(false)
    } catch (e) {
      log.warn('[MeetingRequestBanner] decline failed', e)
      setError(e?.message || 'Couldn’t decline. Try again.')
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className={styles.invite}>
      <div className={styles.main}>
        <div className={styles.head}>
          <span className={styles.icon} aria-hidden="true"><Icon name="calendar" size={18} /></span>
          <div className={styles.meta}>
            <div className={styles.title}>{request.name} requests a {minutes}-minute meeting</div>
            <div className={styles.when}>{when}</div>
            {theirTime && <div className={styles.loc}>{theirTime}</div>}
          </div>
        </div>
        {request.note && <div className={styles.note}>&ldquo;{request.note}&rdquo;</div>}
        {forSomeoneElse ? (
          <div className={styles.responded}>
            <Icon name={status === 'accepted' ? 'checkmark.circle.fill' : 'clock'} size={15} />
            <span>
              {status
                ? `${request.invitee_name || 'The invitee'} ${status === 'accepted' ? 'accepted' : status} this request`
                : `Waiting for ${request.invitee_name || 'the invitee'} to respond`}
            </span>
          </div>
        ) : status ? (
          <div className={styles.responded}>
            <Icon name={status === 'accepted' ? 'checkmark.circle.fill' : 'xmark.circle.fill'} size={15} />
            <span>{STATUS_LABEL[status] || status}</span>
          </div>
        ) : declining ? (
          <div className={styles.declineRow}>
            <input
              className={styles.reasonInput}
              placeholder="Reason (optional, goes in the email)"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') decline() }}
              autoFocus
            />
            <Button disabled={!!busy} aria-busy={busy === 'decline'} onClick={decline}>Send decline</Button>
            <Button variant="secondary" disabled={!!busy} onClick={() => setDeclining(false)}>Back</Button>
          </div>
        ) : (
          <div className={styles.actions}>
            <Button disabled={!!busy} aria-busy={busy === 'accept'} onClick={accept}>Accept</Button>
            <Button variant="secondary" disabled={!!busy} onClick={() => setDeclining(true)}>Decline…</Button>
            <span className={styles.hint}>
              {CONFERENCE_HINT[request.conference_mode] || 'Not on your calendar yet.'}
            </span>
          </div>
        )}
        {notice && <div className={styles.noticeLine}>{notice}</div>}
        {error && <div className={styles.error}>{error}</div>}
      </div>
    </div>
  )
}
