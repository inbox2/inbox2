import { describe, it, expect } from 'vitest';
import { trayTitle } from '../trayTitle';

const NOW = Date.parse('2026-09-21T10:20:00Z');
const at = (mins) => new Date(NOW + mins * 60000).toISOString();

describe('trayTitle', () => {
  it('says nothing when there is nothing to say', () => {
    expect(trayTitle(0, null, NOW)).toBe('');
    expect(trayTitle(0, { title: 'Far off', start: at(180) }, NOW)).toBe('');
  });

  it('shows the unread count, capped', () => {
    expect(trayTitle(12, null, NOW)).toBe('12');
    expect(trayTitle(140, null, NOW)).toBe('99+');
  });

  it('names the next meeting inside the hour', () => {
    expect(trayTitle(0, { title: 'Bijpraten', start: at(10) }, NOW)).toBe('Bijpraten · in 10m');
    expect(trayTitle(3, { title: 'Bijpraten', start: at(0) }, NOW)).toBe('3 · Bijpraten · now');
  });

  it('truncates a long title so the menu bar keeps its room', () => {
    const out = trayTitle(0, { title: 'Quarterly planning review with the whole team', start: at(5) }, NOW);
    expect(out).toBe('Quarterly planning re… · in 5m');
  });

  it('counts a running zone down unless a meeting is about to start', () => {
    const now = Date.parse('2026-09-25T14:18:00Z');
    const zone = { name: 'Project Atlas', start_at: '2026-09-25T14:00:00Z', end_at: '2026-09-25T16:00:00Z' };
    expect(trayTitle(3, null, now, zone)).toBe('3 · Project Atlas · 1:42 left');
    const meeting = { title: 'Standup', start: '2026-09-25T14:25:00Z' };
    expect(trayTitle(0, meeting, now, zone)).toBe('Standup · in 7m');
  });
});
