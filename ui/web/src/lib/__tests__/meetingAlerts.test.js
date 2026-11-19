import { describe, it, expect } from 'vitest'
import { DEFAULT_LEADS, dueAlert, ignoreMeeting, leadsFor, loadFired, minutesLabel, rsvpSummary, snoozeMeeting } from '../meetingAlerts'

// A fixed clock: `dueAlert` compares `now` against the event start to the
// millisecond, so deriving both from Date.now() would make "starting exactly
// now" a coin flip.
const NOW = 1767225600000 // 2026-01-01T00:00:00Z
const evt = (id, minsFromNow, leads = [10, 0]) => ({
  id,
  startAt: new Date(NOW + minsFromNow * 60000),
  leads,
})

describe('dueAlert', () => {
  it('stays quiet until the first lead time is reached', () => {
    expect(dueAlert(evt('a', 25), NOW, {})).toBeNull()
  })

  it('fires the 10-minute lead once, then not again', () => {
    const fired = {}
    const due = dueAlert(evt('b', 9), NOW, fired)
    expect(due).toEqual({ lead: 10, keys: ['b:10'] })
    for (const k of due.keys) fired[k] = 1
    expect(dueAlert(evt('b', 9), NOW, fired)).toBeNull()
  })

  it('fires at the start too, as a separate alert', () => {
    expect(dueAlert(evt('c', 0), NOW, { 'c:10': 1 })).toEqual({ lead: 0, keys: ['c:0'] })
  })

  it('an ignored meeting never alerts again — the at-start nudge included', () => {
    expect(dueAlert(evt('i', 9), NOW, { 'i:ignored': NOW })).toBeNull()
    expect(dueAlert(evt('i', 0), NOW, { 'i:ignored': NOW })).toBeNull()
  })

  it('ignoreMeeting persists the marker into the fired map', () => {
    // Node test env has no localStorage — the lib degrades to no-ops there.
    const store = new Map()
    globalThis.localStorage = {
      getItem: (k) => store.get(k) ?? null,
      setItem: (k, v) => store.set(k, String(v)),
    }
    try {
      ignoreMeeting('j', NOW)
      expect(loadFired()['j:ignored']).toBe(NOW)
      expect(dueAlert(evt('j', 9), NOW, loadFired())).toBeNull()
    } finally {
      delete globalThis.localStorage
    }
  })

  it('collapses a missed lead into the honest one when catching up', () => {
    // App launched at T-1: both leads are past. Show the one closest to the
    // start, and spend the 10-minute one rather than replaying it afterwards.
    expect(dueAlert(evt('d', -1), NOW, {})).toEqual({ lead: 0, keys: ['d:10', 'd:0'] })
  })

  it('never replays a meeting that is well over', () => {
    expect(dueAlert(evt('e', -30), NOW, {})).toBeNull()
  })

  it('honours the event\'s own lead times', () => {
    expect(dueAlert(evt('f', 50, [60, 5]), NOW, {})).toEqual({ lead: 60, keys: ['f:60'] })
    expect(dueAlert(evt('g', 50, [30]), NOW, {})).toBeNull()
  })

  it('holds an alert back while snoozed, then lets it through', () => {
    // snoozeMeeting stamps against the real clock, so this one runs on it.
    const now = Date.now()
    const meeting = { id: 'h', startAt: new Date(now + 2 * 60000), leads: [10, 0] }
    snoozeMeeting('h')
    expect(dueAlert(meeting, now, {})).toBeNull()
    // Five minutes on, the hold has expired and the un-fired key comes due.
    expect(dueAlert(meeting, now + 5 * 60000 + 1, {})).not.toBeNull()
  })
})

describe('leadsFor', () => {
  it('uses the event\'s own popup reminders', () => {
    expect(leadsFor([{ method: 'popup', minutes_before: 30 }, { method: 'popup', minutes_before: 5 }])).toEqual([30, 5])
  })

  it('ignores email reminders and duplicates', () => {
    expect(leadsFor([
      { method: 'email', minutes_before: 30 },
      { method: 'popup', minutes_before: 5 },
      { method: 'popup', minutes_before: 5 },
    ])).toEqual([5])
  })

  it('falls back to the default when the only reminder is further out than we look', () => {
    // A "1 day before" reminder can't be honoured by a two-hour tick, so give
    // the usual nudge rather than firing it late and mislabelled.
    expect(leadsFor([{ method: 'popup', minutes_before: 1440 }])).toEqual(DEFAULT_LEADS)
    expect(leadsFor([])).toEqual(DEFAULT_LEADS)
  })
})

describe('minutesLabel', () => {
  it('names the moment', () => {
    expect(minutesLabel(new Date(NOW + 10 * 60000), NOW)).toBe('Meeting in 10 minutes')
    expect(minutesLabel(new Date(NOW + 60000), NOW)).toBe('Meeting in 1 minute')
    expect(minutesLabel(new Date(NOW), NOW)).toBe('Starting now')
    expect(minutesLabel(new Date(NOW - 60000), NOW)).toBe('Starting now')
    expect(minutesLabel(new Date(NOW + 90 * 60000), NOW)).toBe('Meeting in 2 hours')
  })
})

describe('rsvpSummary', () => {
  it('counts the whole list, in either field casing', () => {
    expect(rsvpSummary([
      { responseStatus: 'accepted' },
      { response_status: 'accepted' },
      { responseStatus: 'tentative' },
      { responseStatus: 'needsAction' },
      { response_status: 'declined' },
    ])).toBe('2 accepted · 1 tentative · 1 declined')
  })

  it('falls back to a head count when nobody has answered', () => {
    expect(rsvpSummary([{ responseStatus: 'needsAction' }, {}])).toBe('2 attendees')
    expect(rsvpSummary([])).toBeNull()
    expect(rsvpSummary(undefined)).toBeNull()
  })
})
