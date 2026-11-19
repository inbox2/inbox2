import { describe, it, expect } from 'vitest'
import { detectMeetingProvider } from '../meetingProvider'

describe('detectMeetingProvider', () => {
  it('matches known conferencing hosts in any field', () => {
    expect(detectMeetingProvider('https://acme.zoom.us/j/123')).toBe('zoom')
    expect(detectMeetingProvider(null, 'Join at https://meet.google.com/abc-defg-hij')).toBe('meet')
    expect(detectMeetingProvider('Microsoft Teams Meeting', 'https://teams.microsoft.com/l/x')).toBe('teams')
    expect(detectMeetingProvider('https://company.webex.com/meet/x')).toBe('webex')
  })

  it('returns null when no host matches or all fields empty', () => {
    expect(detectMeetingProvider('Conference Room B')).toBeNull()
    expect(detectMeetingProvider(null, undefined, '')).toBeNull()
  })

  it('honours first-match precedence across fields', () => {
    // location wins over a stray teams mention in the description
    expect(detectMeetingProvider('https://x.zoom.us/j/1', 'also has teams.microsoft.com')).toBe('zoom')
  })
})
