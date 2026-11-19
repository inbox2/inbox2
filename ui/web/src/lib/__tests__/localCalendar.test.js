import { describe, it, expect } from 'vitest'
import { pickNext, layoutDay } from '../localCalendar'

const NOW = Date.parse('2026-07-31T09:00:00Z')

describe('pickNext', () => {
  it('picks the earliest future event across mixed RFC3339 offsets', () => {
    // Lexically "+02:00" sorts before "Z", but 10:30+02:00 is 08:30Z — in the past.
    const rows = [
      { title: 'Standup', start_at: '2026-07-31T10:30:00+02:00', calendar_name: 'Work' },
      { title: 'Review', start_at: '2026-07-31T09:30:00Z', calendar_name: 'Work' },
      { title: 'Retro', start_at: '2026-07-31T14:00:00+02:00', calendar_name: 'Work' },
    ]
    const next = pickNext(rows, NOW)
    expect(next.title).toBe('Review')
    expect(next.soon).toBe(true) // 30m out
  })

  it('returns null when everything is in the past', () => {
    expect(pickNext([{ title: 'Done', start_at: '2026-07-30T09:00:00Z' }], NOW)).toBe(null)
    expect(pickNext([], NOW)).toBe(null)
  })
})

describe('layoutDay', () => {
  const day = new Date(2026, 6, 31)
  const at = (h, m = 0) => new Date(2026, 6, 31, h, m)

  it('places events by minutes from midnight and keeps the default window', () => {
    const { spans, hours, originMin } = layoutDay([{ start: at(10), end: at(11, 30) }], day)
    expect(spans[0]).toMatchObject({ from: 600, to: 690 })
    expect(originMin).toBe(7 * 60)
    expect(hours[0]).toBe(7)
    expect(hours[hours.length - 1]).toBe(20)
  })

  it('widens the window for an early event', () => {
    expect(layoutDay([{ start: at(6), end: at(6, 30) }], day).hours[0]).toBe(6)
  })

  it('clamps an event straddling the day to midnight..midnight', () => {
    const { spans, hours } = layoutDay(
      [{ start: new Date(2026, 6, 30, 22), end: new Date(2026, 7, 1, 2) }], day
    )
    expect(spans[0]).toMatchObject({ from: 0, to: 24 * 60 })
    expect(hours[0]).toBe(0) // the clamped span pulls the window open to midnight
  })

  it('splits concurrent events into side-by-side columns', () => {
    const { spans } = layoutDay([
      { key: 'a', start: at(12), end: at(13) },
      { key: 'b', start: at(12), end: at(12, 30) },
      { key: 'c', start: at(14), end: at(15) }, // after the cluster — full width again
    ], day)
    const by = Object.fromEntries(spans.map((s) => [s.key, s]))
    expect([by.a.col, by.b.col].sort()).toEqual([0, 1])
    expect(by.a.cols).toBe(2)
    expect(by.b.cols).toBe(2)
    expect(by.c).toMatchObject({ col: 0, cols: 1 })
  })

  it('reuses a column once its event has ended', () => {
    const { spans } = layoutDay([
      { key: 'a', start: at(9), end: at(10) },
      { key: 'b', start: at(9, 30), end: at(11) }, // overlaps a → column 1
      { key: 'c', start: at(10), end: at(10, 30) }, // a is done → back to column 0
    ], day)
    const by = Object.fromEntries(spans.map((s) => [s.key, s]))
    expect(by.a.col).toBe(0)
    expect(by.b.col).toBe(1)
    expect(by.c.col).toBe(0)
    expect(by.c.cols).toBe(2) // still the same cluster (b is open), so widths match
  })

  it('drops all-day events from the timed grid', () => {
    expect(layoutDay([{ start: at(0), end: at(23, 59), allDay: true }], day).spans).toHaveLength(0)
  })
})
