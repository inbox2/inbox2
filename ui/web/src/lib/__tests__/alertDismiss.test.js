import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('../tauri', async (orig) => ({ ...(await orig()), isTauri: () => false }));

import useNotificationStore from '../../stores/notificationStore';
import { alertMatches, closeAlertsFor } from '../alertDismiss';

const flush = () => new Promise((r) => setTimeout(r, 0));

describe('alertDismiss', () => {
  beforeEach(() => useNotificationStore.setState({ notifications: [] }));

  it('matches a card by conversation, including merged reply cards', () => {
    expect(alertMatches({ key: 'c1' }, ['c1'])).toBe(true);
    expect(alertMatches({ conversationId: 'c2', key: 'x' }, ['c2'])).toBe(true);
    expect(alertMatches({ _isMerged: true, items: [{ key: 'a' }, { key: 'c3' }] }, ['c3'])).toBe(true);
    expect(alertMatches({ key: 'other' }, ['c1'])).toBe(false);
  });

  it('closes the alert for a thread deleted elsewhere, leaves the rest', async () => {
    useNotificationStore.setState({ notifications: [{ _alertId: 1, key: 'c1' }, { _alertId: 2, key: 'c2' }] });
    await closeAlertsFor(['c1'], 'trash');
    await flush();
    expect(useNotificationStore.getState().notifications.map((n) => n.key)).toEqual(['c2']);
  });

  it('keeps the alert for actions that leave the thread in the inbox', async () => {
    useNotificationStore.setState({ notifications: [{ _alertId: 1, key: 'c1' }] });
    await closeAlertsFor(['c1'], 'mark_read');
    await flush();
    expect(useNotificationStore.getState().notifications).toHaveLength(1);
  });
});
