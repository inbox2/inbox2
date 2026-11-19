// @vitest-environment jsdom
//
// The views are the sidebar's Inbox/Sent/Drafts: one failed request used to leave
// them missing until the next org switch.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';

vi.mock('../../lib/log', () => ({ default: { warn: () => {}, info: () => {}, error: () => {} } }));
vi.mock('../../components/LabelsField/LabelsField', () => ({ TAGS_CHANGED: 'tags-changed' }));
vi.mock('../../lib/api', () => ({ default: { getTags: async () => ({ tags: [] }) } }));
const getViews = vi.fn();
vi.mock('../../lib/localFirstApi', () => ({
  default: { getViews: (...a) => getViews(...a), getTags: async () => ({ tags: [] }) },
}));

const { default: useViewsAndTags } = await import('../useViewsAndTags');
globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const INBOX = { id: 'view_1', name: 'Inbox', kind: 'system' };
const OPTS = { activeView: INBOX, setActiveView: () => {} };

function mount() {
  const held = {};
  function Probe() { held.result = useViewsAndTags('org_1', OPTS); return null; }
  const root = createRoot(document.createElement('div'));
  act(() => root.render(createElement(Probe)));
  held.unmount = () => act(() => root.unmount());
  return held;
}
const tick = (ms) => act(async () => { await vi.advanceTimersByTimeAsync(ms); });

describe('useViewsAndTags', () => {
  beforeEach(() => { vi.useFakeTimers(); getViews.mockReset(); });
  afterEach(() => { vi.useRealTimers(); });

  it('retries a failed views load instead of leaving the folders empty', async () => {
    getViews.mockRejectedValueOnce(new Error('503')).mockResolvedValue({ views: [INBOX] });
    const held = mount();
    await tick(0);
    expect(held.result.views).toEqual([]);
    await tick(2000);
    expect(getViews).toHaveBeenCalledTimes(2);
    expect(held.result.views).toEqual([INBOX]);
    held.unmount();
  });

  it('stops retrying after unmount', async () => {
    getViews.mockRejectedValue(new Error('503'));
    const held = mount();
    await tick(0);
    held.unmount();
    await vi.advanceTimersByTimeAsync(60000);
    expect(getViews).toHaveBeenCalledTimes(1);
  });
});
