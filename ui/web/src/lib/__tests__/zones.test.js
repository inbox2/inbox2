import { describe, expect, it } from 'vitest';
import { isActive, prepZoneParams, progress, remaining, zoneColorVar } from '../zones';

const zone = { start_at: '2026-09-25T14:00:00Z', end_at: '2026-09-25T16:00:00Z' };
const at = (iso) => Date.parse(iso);

describe('zones', () => {
  it('knows when a zone is running', () => {
    expect(isActive(zone, at('2026-09-25T13:59:59Z'))).toBe(false);
    expect(isActive(zone, at('2026-09-25T14:00:00Z'))).toBe(true);
    expect(isActive(zone, at('2026-09-25T16:00:00Z'))).toBe(false);
  });

  it('counts down what is left', () => {
    const now = at('2026-09-25T14:18:08Z');
    expect(remaining(zone, now, { withSeconds: true })).toBe('1:41:52');
    expect(remaining(zone, now)).toBe('1:41');
    expect(remaining(zone, at('2026-09-25T15:20:00Z'))).toBe('40m');
    expect(remaining(zone, at('2026-09-25T17:00:00Z'))).toBe('0m');
    expect(progress(zone, at('2026-09-25T15:00:00Z'))).toBe(0.5);
  });

  it('builds a prep zone that ends when the meeting starts', () => {
    const cats = [{ id: 'zcat_1', name: 'Deep work' }, { id: 'zcat_2', name: 'Prep' }];
    const p = prepZoneParams({ title: 'Q3 board review', start_at: '2026-09-24T14:00:00Z' }, 60, cats);
    expect(p).toMatchObject({ name: 'Prep: Q3 board review', category_id: 'zcat_2', notify: true });
    expect(p.start_at).toBe('2026-09-24T13:00:00.000Z');
    expect(p.end_at).toBe('2026-09-24T14:00:00.000Z');
    expect(prepZoneParams({ title: 'x', start_at: '2026-09-24T14:00:00Z' }, 30, []).category_id).toBeNull();
  });

  it('falls back to blue for an unknown colour', () => {
    expect(zoneColorVar('teal')).toBe('var(--zone-teal)');
    expect(zoneColorVar('#ff00ff')).toBe('var(--zone-blue)');
  });
});

describe('prep zone anchors', () => {
  const zone = { anchor_event_id: 'cev_1', anchor_minutes: 60, start_at: '2026-09-24T13:00:00Z', end_at: '2026-09-24T14:00:00Z' };

  it('anchors a new prep zone to its meeting', async () => {
    const { prepZoneParams } = await import('../zones');
    const p = prepZoneParams({ id: 'cev_1', title: 'Board', start_at: '2026-09-24T14:00:00Z' }, 60, []);
    expect(p).toMatchObject({ anchor_event_id: 'cev_1', anchor_minutes: 60 });
  });

  it('follows a moved meeting and leaves a still one alone', async () => {
    const { anchorFix } = await import('../zones');
    expect(anchorFix(zone, [{ id: 'cev_1', start_at: '2026-09-24T14:00:00Z' }])).toBeNull();
    expect(anchorFix(zone, [{ id: 'cev_1', start_at: '2026-09-24T16:30:00Z' }])).toEqual({
      start_at: '2026-09-24T15:30:00.000Z', end_at: '2026-09-24T16:30:00.000Z',
    });
    expect(anchorFix(zone, [{ id: 'cev_1', start_at: '2026-09-24T16:30:00Z', status: 'cancelled' }])).toBeNull();
    expect(anchorFix(zone, [])).toBeNull();
    expect(anchorFix({ ...zone, anchor_event_id: null }, [{ id: 'cev_1', start_at: '2026-09-24T16:30:00Z' }])).toBeNull();
  });
});

describe('alert stack', () => {
  it('never evicts a zone card to make room', async () => {
    const { keepVisible } = await import('../../stores/notificationStore');
    const mail = (k) => ({ key: k });
    const zone = { key: 'zone:1', eventType: 'zone_start' };
    const out = keepVisible([mail('a'), mail('b'), mail('c'), zone], 3);
    expect(out).toContain(zone);
    expect(out.map(n => n.key)).toEqual(['a', 'b', 'zone:1']);
  });
});
