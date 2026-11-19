import { describe, it, expect } from 'vitest'
import { detectMeeting, findMeetingUrl } from '../meetingProvider'

// Real invite shapes — one per way a join link reaches us.
describe('detectMeeting', () => {
  it('prefers the provider\'s structured link over the body', () => {
    const evt = {
      conference: { url: 'https://teams.microsoft.com/l/meetup-join/19%3ameet%40thread.v2/0', label: 'Microsoft Teams', code: '412 998 116' },
      description: 'Dial-in fallback: https://zoom.us/j/000',
    }
    expect(detectMeeting(evt)).toEqual({
      url: 'https://teams.microsoft.com/l/meetup-join/19%3ameet%40thread.v2/0',
      provider: 'teams',
      label: 'Microsoft Teams',
      code: '412 998 116',
    })
  })

  it('reads a Meet link out of the location', () => {
    expect(detectMeeting({ location: 'https://meet.google.com/wqf-rhzt-yjk' })).toMatchObject({
      provider: 'meet',
      url: 'https://meet.google.com/wqf-rhzt-yjk',
      label: 'Google Meet',
    })
  })

  it('keeps the Zoom passcode through HTML entity encoding', () => {
    const evt = { description: '<a href="https://us02web.zoom.us/j/8412?pwd=Q1V6&amp;from=addon">Join</a>' }
    expect(detectMeeting(evt).url).toBe('https://us02web.zoom.us/j/8412?pwd=Q1V6&from=addon')
  })

  it('drops trailing prose punctuation', () => {
    expect(findMeetingUrl('Call in here (https://zoom.us/j/9).')).toBe('https://zoom.us/j/9')
  })

  it('returns null for an event with no way in', () => {
    expect(detectMeeting({ location: 'Keizersgracht 62, Amsterdam', title: 'Lunch' })).toBeNull()
    expect(detectMeeting(null)).toBeNull()
  })

  it('labels an unknown host generically rather than dropping it', () => {
    const evt = { conference: { url: 'https://whereby.com/inbox2', label: 'Whereby' } }
    expect(detectMeeting(evt)).toMatchObject({ provider: null, label: 'Whereby', url: 'https://whereby.com/inbox2' })
  })
})
