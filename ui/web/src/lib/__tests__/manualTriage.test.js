import { describe, it, expect, vi } from 'vitest';
import { triageSubmenu } from '../conversationActions';
import { manualTriageTarget } from '../../hooks/useManualTriage';

const manual = (over = {}) => ({
  spaces: [{ slug: 'sales', name: 'Sales' }, { slug: 'triage', name: 'Triage' }],
  labels: [{ slug: 'needs_answer', name: 'Needs answer' }, { slug: 'fyi', name: 'FYI' }],
  currentSpace: 'sales',
  currentLabel: 'fyi',
  moveToSpace: vi.fn(),
  setLabel: vi.fn(),
  rerun: vi.fn(),
  ...over,
});

describe('triageSubmenu', () => {
  it('is the Eisenhower quadrants alone without manual triage', () => {
    const values = triageSubmenu(['c1'], vi.fn()).submenu.map((i) => i.value);
    expect(values).not.toContain('triage_space');
    expect(values).toContain('triage_clear');
  });

  it('puts Move to Space, Label and Re-run Jev before the quadrants, current ones checked', () => {
    const m = manual();
    const after = vi.fn();
    const items = triageSubmenu(['c1'], vi.fn(), { manual: m, afterAction: after }).submenu;
    expect(items.slice(0, 4).map((i) => i.value || 'sep')).toEqual(['triage_space', 'triage_label', 'triage_rerun', 'sep']);

    const [space, label, rerun] = items;
    expect(space.submenu.map((s) => s.checked)).toEqual([true, false]);
    expect(label.submenu.map((s) => s.checked)).toEqual([false, true]);

    space.submenu[1].onSelect();
    label.submenu[0].onSelect();
    rerun.onSelect();
    expect(m.moveToSpace).toHaveBeenCalledWith('triage');
    expect(m.setLabel).toHaveBeenCalledWith('needs_answer');
    expect(m.rerun).toHaveBeenCalled();
    expect(after).toHaveBeenCalledTimes(3);
  });

  it('omits a list that has not loaded yet', () => {
    const values = triageSubmenu(['c1'], vi.fn(), { manual: manual({ spaces: null, labels: [] }) }).submenu.map((i) => i.value);
    expect(values.slice(0, 1)).toEqual(['triage_rerun']);
  });
});

describe('manualTriageTarget', () => {
  it('reads local vs MX from providerType, else from key', () => {
    expect(manualTriageTarget({ id: 'k1', key: 'k1', triage_label: 'fyi' }, 'org_1')).toMatchObject({ id: 'k1', local: true, orgId: null, label: 'fyi' });
    expect(manualTriageTarget({ id: 'conv_1', space: { slug: 'sales' } }, 'org_1')).toMatchObject({ id: 'conv_1', local: false, orgId: 'org_1', space: 'sales' });
    // Unified columns give MX rows a key too; providerType wins.
    expect(manualTriageTarget({ id: 'conv_2', key: 'conv_2', providerType: 'inbox2', orgKey: 'org_9' }, 'org_1')).toMatchObject({ local: false, orgId: 'org_9' });
    expect(manualTriageTarget({ id: 'k2', key: 'k2', providerType: 'gmail' }, 'org_1')).toMatchObject({ local: true });
    expect(manualTriageTarget(null, 'org_1')).toBeNull();
  });
});
