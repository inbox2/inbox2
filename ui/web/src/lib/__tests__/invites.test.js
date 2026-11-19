import { describe, it, expect } from 'vitest';
import { isRequest, attachmentIsCalendar, formatWhen, inviteForAlert } from '../invites';

describe('isRequest', () => {
  it('rejects a stated non-REQUEST method (PUBLISH confirmations, bookings)', () => {
    expect(isRequest({ method: 'PUBLISH', attachment_id: 'a1', organizer_email: 'x@y.z' })).toBe(false);
  });

  it('treats an MX invite (no attachment id) as answerable', () => {
    expect(isRequest({ method: 'REQUEST' })).toBe(true);
  });

  it('needs an organizer on a local-channel invite — nobody to answer otherwise', () => {
    expect(isRequest({ attachment_id: 'a1' })).toBe(false);
    expect(isRequest({ attachment_id: 'a1', organizer_email: 'boss@example.com' })).toBe(true);
  });
});

describe('attachmentIsCalendar', () => {
  it('matches by mime type or .ics filename, and nothing else', () => {
    expect(attachmentIsCalendar({ mimeType: 'text/calendar' })).toBe(true);
    expect(attachmentIsCalendar({ filename: 'Invite.ICS' })).toBe(true);
    expect(attachmentIsCalendar({ filename: 'agenda.pdf', mimeType: 'application/pdf' })).toBe(false);
  });
});

describe('formatWhen', () => {
  it('says all-day without inventing a time', () => {
    expect(formatWhen({ start: '2026-09-09', all_day: true })).toMatch(/All day$/);
  });

  it('is null when there is no start to show', () => {
    expect(formatWhen({})).toBeNull();
  });
});

describe('inviteForAlert', () => {
  it('probes nothing off the desktop, or without an attachment to probe', async () => {
    await expect(inviteForAlert({ hasAttachment: true, messageKey: 'm1', accountKey: 'a1' })).resolves.toBeNull();
    await expect(inviteForAlert({ hasAttachment: false })).resolves.toBeNull();
  });
});
