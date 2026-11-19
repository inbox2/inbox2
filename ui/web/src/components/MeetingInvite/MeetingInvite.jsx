import { useState, useEffect, useContext } from 'react'
import { useNavigate, useParams } from 'react-router'
import Button from '../Button/Button'
import Icon from '../Icon'
import { isTauri } from '../../lib/tauri'
import { resolveAccountKey } from '../../lib/draftAttachments'
import api from '../../lib/api'
import { isRealOrgId } from '../../lib/org'
import { AuthContext } from '../../hooks/AuthProvider'
import { resolveWorkspace } from '../../lib/workspace'
import useCalendarStore from '../../stores/calendarStore'
import { isRequest, attachmentIsCalendar, formatWhen, inviteInstant } from '../../lib/invites'
import log from '../../lib/log'
import InviteSchedule from './InviteSchedule'
import MeetingProviderIcon from '../MeetingProviderIcon/MeetingProviderIcon'
import { detectMeetingProvider } from '../MeetingProviderIcon/meetingProvider'
import styles from './MeetingInvite.module.css'

// Outlook-style meeting-invite banner shown just below the email header. Two
// sources (docs/Meeting-Invites.md): MX messages carry a pre-parsed `invite`
// object from the API; local-channel (Gmail/IMAP) messages are resolved from the
// Rust core via their text/calendar attachment. RSVP writes back to the matching
// source.
//
// A third source: no ICS at all, but the triage summary lane read a booked
// meeting out of the body ("Detected meetings"). It arrives as the same invite
// shape with `detected: true` (MX via the serializer, local via the core's
// `detected_invite`), is marked as detected, and only offers "Add to calendar" —
// or says it's already there when the calendar has an event at that time.
const RESPONSES = [
  { key: 'accepted', label: 'Accept' },
  { key: 'tentative', label: 'Tentative' },
  { key: 'declined', label: 'Decline' },
]

const STATUS_LABEL = { accepted: 'You accepted', tentative: "You're tentative", declined: 'You declined' }

export default function MeetingInvite({ message, attachments, orgId, onAnswered }) {
  const mxInvite = message?.invite || null
  const calAtt = (attachments || []).find(attachmentIsCalendar)

  const navigate = useNavigate()
  const { orgSlug: paramOrgSlug } = useParams()
  // Context directly, not useAuth(): the auth values below are already optional
  // and this renders inside message cards that Storybook mounts provider-less.
  const auth = useContext(AuthContext)
  const orgSlug = paramOrgSlug || auth?.currentOrgSlug
  const orgPrimarySlug = resolveWorkspace(auth?.organizations, orgSlug).org?.slug || orgSlug

  const [localInvite, setLocalInvite] = useState(null)
  const [status, setStatus] = useState(mxInvite?.rsvp_status && mxInvite.rsvp_status !== 'needs_action' ? mxInvite.rsvp_status : null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  // Once answered we collapse to a compact "You responded · Change" row;
  // "Change" re-reveals the buttons so the user can switch their response.
  const [changing, setChanging] = useState(false)
  // "Add to calendar" (non-REQUEST ICS): the event key once added, so the banner
  // flips to a confirmation instead of offering to add it twice.
  const [addedKey, setAddedKey] = useState(null)

  // An event already on the calendar at the detected meeting's time (reported by
  // InviteSchedule) — the meeting was scheduled some other way.
  const [sameTime, setSameTime] = useState(null)

  // Resolve a local-channel invite (desktop only) when the message has no MX
  // invite: from its text/calendar attachment, else a detected meeting.
  useEffect(() => {
    let alive = true
    if (mxInvite || !isTauri()) return undefined
    ;(async () => {
      try {
        const accountKey = await resolveAccountKey(message)
        if (!accountKey) return
        const { inviteForAttachment, detectedInvite } = await import('../../lib/providers/index.js')
        const inv = calAtt
          ? await inviteForAttachment(accountKey, message.key || message.id, calAtt.attachmentId)
          : await detectedInvite(accountKey, message.key || message.id)
        // Both shapes are kept: a REQUEST gets the RSVP buttons, anything else gets
        // "Add to calendar".
        if (alive && inv) {
          setLocalInvite(inv)
          if (inv.current_status && inv.current_status !== 'needs_action') setStatus(inv.current_status)
          // Already on the calendar (synced, or added on an earlier read) — a
          // present-but-empty key still means added, it just has nothing to link to.
          if (!isRequest(inv) && inv.matched_event_key != null) setAddedKey(inv.matched_event_key)
        }
      } catch (e) {
        log.warn('[MeetingInvite] resolve failed', e)
      }
    })()
    return () => { alive = false }
  }, [message, calAtt, mxInvite])

  const invite = mxInvite || localInvite
  if (!invite) return null

  // Tapping the event info opens the calendar straight to this event's detail —
  // only when the invite maps to a synced calendar event (local channels).
  const eventKey = invite.matched_event_key
  const canOpen = !!eventKey && !!orgPrimarySlug
  function openInCalendar() {
    if (!canOpen) return
    // Move the calendar to the event's date so it's in the loaded window, then
    // deep-link to it (CalendarPage opens its detail popup from the :eventId).
    if (invite.start) useCalendarStore.getState().setCurrentDate(inviteInstant(invite.start, invite.timezone))
    navigate(`/${orgPrimarySlug}/calendar/${eventKey}`)
  }

  async function respond(resp) {
    setBusy(resp)
    setError(null)
    try {
      if (mxInvite) {
        if (!isRealOrgId(orgId)) throw new Error('no org')
        await api.post(`/orgs/${orgId}/messages/${message.key || message.id}/rsvp`, { status: resp })
      } else {
        const accountKey = await resolveAccountKey(message)
        const { respondToInvite } = await import('../../lib/providers/index.js')
        await respondToInvite(accountKey, message.key || message.id, calAtt.attachmentId, resp)
      }
      setStatus(resp)
      setChanging(false)
      onAnswered?.()
    } catch (e) {
      log.warn('[MeetingInvite] rsvp failed', e)
      setError('Couldn’t send your reply. Try again.')
    } finally {
      setBusy(null)
    }
  }

  async function addToCalendar() {
    setBusy('add')
    setError(null)
    try {
      if (mxInvite) {
        if (!isRealOrgId(orgId)) throw new Error('no org')
        // A detected meeting's time is the sender's wall clock: the server reads it in our zone.
        const { data } = await api.post(`/orgs/${orgId}/messages/${message.key || message.id}/calendar-import`,
          { time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone })
        setAddedKey(data?.event?.key || '')
      } else if (invite.detected) {
        const accountKey = await resolveAccountKey(message)
        const { addDetectedMeetingToCalendar } = await import('../../lib/providers/index.js')
        setAddedKey(await addDetectedMeetingToCalendar(accountKey, message.key || message.id))
      } else {
        const accountKey = await resolveAccountKey(message)
        const { addInviteToCalendar } = await import('../../lib/providers/index.js')
        setAddedKey(await addInviteToCalendar(accountKey, message.key || message.id, calAtt.attachmentId))
      }
    } catch (e) {
      log.warn('[MeetingInvite] add to calendar failed', e)
      // Show the engine's own reason — a guessed one ("no calendar?") sends the
      // user looking in the wrong place.
      setError(`Couldn't add it: ${e?.message || e}`)
    } finally {
      setBusy(null)
    }
  }

  const addable = !isRequest(invite)
  const answered = !!status && !changing

  const when = formatWhen(invite)
  const provider = detectMeetingProvider(invite.location, invite.description, invite.summary, invite.url)
  const headInner = (
    <>
      <span className={styles.icon} aria-hidden="true">
        {provider ? <MeetingProviderIcon provider={provider} size={20} /> : <Icon name="calendar" size={18} />}
      </span>
      <div className={styles.meta}>
        <div className={styles.title}>{invite.summary || 'Meeting invitation'}</div>
        {when && <div className={styles.when}>{when}</div>}
        {invite.location && <div className={styles.loc}>{invite.location}</div>}
      </div>
    </>
  )
  return (
    <div className={`${styles.invite} ${invite.detected ? styles.detected : ''}`}>
      <div className={styles.main}>
      {invite.detected && (
        <div className={styles.detectedTag}>
          <Icon name="sparkles" size={12} />
          <span>Found in this email</span>
        </div>
      )}
      {canOpen ? (
        <button type="button" className={`${styles.head} ${styles.headButton}`} onClick={openInCalendar} title="Open in calendar">
          {headInner}
          <span className={styles.chev} aria-hidden="true"><Icon name="chevron.right" size={14} /></span>
        </button>
      ) : (
        <div className={styles.head}>{headInner}</div>
      )}
      {addable ? (
        addedKey != null ? (
          <div className={styles.responded}>
            <Icon name="checkmark.circle.fill" size={15} />
            <span>Added to calendar</span>
            {canOpen && <Button variant="link" onClick={openInCalendar}>View</Button>}
          </div>
        ) : invite.detected && sameTime ? (
          <div className={styles.responded}>
            <Icon name="checkmark.circle.fill" size={15} />
            <span>Already on your calendar: {sameTime.title}</span>
          </div>
        ) : (
          <div className={styles.actions}>
            <Button disabled={!!busy} aria-busy={busy === 'add'} onClick={addToCalendar}>
              Add to calendar
            </Button>
          </div>
        )
      ) : answered ? (
        <div className={styles.responded}>
          <Icon name="checkmark.circle.fill" size={15} />
          <span>{STATUS_LABEL[status] || status}</span>
          <Button variant="link" onClick={() => setChanging(true)}>Change</Button>
        </div>
      ) : (
        <div className={styles.actions}>
          {RESPONSES.map((r) => (
            <Button
              key={r.key}
              variant={status === r.key ? undefined : 'secondary'}
              disabled={!!busy}
              aria-busy={busy === r.key}
              className={busy && busy !== r.key ? styles.dim : undefined}
              onClick={() => respond(r.key)}
            >
              {r.label}
            </Button>
          ))}
        </div>
      )}
      {error && <div className={styles.error}>{error}</div>}
      </div>
      <InviteSchedule invite={invite} message={message} onSameTime={invite.detected ? setSameTime : undefined} />
    </div>
  )
}
