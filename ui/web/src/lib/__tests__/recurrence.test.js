import { describe, it, expect } from 'vitest'
import { NO_REPEAT, buildRRule, describeRepeat, parseRRule } from '../recurrence'

// 26 Oct 2026 is a Monday.
const START = '2026-10-26T14:00'

describe('recurrence', () => {
  it('saves nothing for a one-off', () => {
    expect(buildRRule(NO_REPEAT, START, false)).toBeNull()
  })

  it('Mon + Wed, twice, then stop', () => {
    const r = { ...NO_REPEAT, freq: 'WEEKLY', days: ['WE', 'MO'], ends: 'after', count: 2 }
    expect(buildRRule(r, START, false)).toBe('FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2')
    expect(describeRepeat(r, START)).toBe('Weekly on Mon, Wed · 2 times')
  })

  it('weekly with no day picked repeats on the start day', () => {
    expect(buildRRule({ ...NO_REPEAT, freq: 'WEEKLY' }, START, false)).toBe('FREQ=WEEKLY;BYDAY=MO')
  })

  it('UNTIL is a DATE for all-day, UTC for timed', () => {
    const r = { ...NO_REPEAT, freq: 'DAILY', interval: 2, ends: 'on', until: '2026-11-30' }
    expect(buildRRule(r, START, true)).toBe('FREQ=DAILY;INTERVAL=2;UNTIL=20261130')
    expect(buildRRule(r, START, false)).toMatch(/^FREQ=DAILY;INTERVAL=2;UNTIL=2026113\dT\d{6}Z$/)
  })

  it('reads a rule back into the editor, and keeps one it cannot show', () => {
    const rule = 'FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2'
    expect(buildRRule(parseRRule(rule), START, false)).toBe(rule)
    expect(parseRRule('FREQ=MONTHLY;BYMONTHDAY=26;INTERVAL=2', START)).toMatchObject({ freq: 'MONTHLY', interval: 2 })
    // The 15th of a series that starts on the 26th can't be redrawn as "monthly".
    expect(parseRRule('FREQ=MONTHLY;BYMONTHDAY=15', START).freq).toBe('custom')
    expect(parseRRule('FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=26', START).freq).toBe('custom')
    // A month filter on a monthly rule is a filter, not the start's month.
    expect(parseRRule('FREQ=MONTHLY;BYMONTH=10', START).freq).toBe('custom')
    expect(parseRRule('FREQ=DAILY;UNTIL=20261130').until).toBe('2026-11-30')
    const custom = parseRRule('FREQ=MONTHLY;BYDAY=-1FR')
    expect(custom.freq).toBe('custom')
    expect(buildRRule(custom, START, false)).toBe('FREQ=MONTHLY;BYDAY=-1FR')
    expect(parseRRule(null)).toBe(NO_REPEAT)
    // A week start set elsewhere survives the round trip.
    expect(buildRRule(parseRRule('FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU', START), START, false)).toBe('FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU')
  })

  it('an "on date" end is never empty or before the start', () => {
    const r = { ...NO_REPEAT, freq: 'DAILY', ends: 'on', until: '' }
    expect(buildRRule(r, START, true)).toBe('FREQ=DAILY;UNTIL=20261026')
    expect(buildRRule({ ...r, until: '2026-01-01' }, START, true)).toBe('FREQ=DAILY;UNTIL=20261026')
  })
})
