import { describe, it, expect } from 'vitest';
import { buildBoard, compareRows, personalCells, mxQuery, localWhere, BOARD_VIEW, BOARD_METRIC } from '../spaceBoard';
import { spaceColor } from '../spaceColors';

const spaces = [
  { id: 'support', key: 'spc_1', name: 'Support', openness: 'org', members: [], open: 9, unread: 2, volume: 30, unassigned: 4 },
  { id: 'triage', key: 'spc_2', name: 'Triage', openness: 'org', members: [], open: 1, unread: 1, volume: 5, unassigned: 1 },
];

const mxConv = (id, at, extra = {}) => ({
  id, subject: id, from_address: 'Maya <maya@acme.com>', updated_at: at, read: true, ...extra,
});
const localConv = (key, at, extra = {}) => ({
  key, subject: key, from_address: 'jan@example.nl', updated_at: at, read: 1, account_key: 'acc_1', ...extra,
});

describe('compareRows', () => {
  it('puts the highest priority first, untriaged last, then newest', () => {
    const rows = [
      { id: 'old-urgent', priority: 4, at: 1 },
      { id: 'new-none', priority: -1, at: 9 },
      { id: 'new-low', priority: 1, at: 8 },
      { id: 'old-low', priority: 1, at: 2 },
    ].sort(compareRows);
    expect(rows.map((r) => r.id)).toEqual(['old-urgent', 'new-low', 'old-low', 'new-none']);
  });
});

describe('buildBoard', () => {
  const mx = {
    support: {
      total: 2,
      rows: [
        mxConv('m-new', '2026-09-19T10:00:00Z', { triage_label: 'needs_answer', assignees: [{ id: 'mem_1', name: 'Maya' }] }),
        mxConv('m-urgent', '2026-09-01T10:00:00Z', { triage_priority: 3.8, triage_label: 'legal_review' }),
      ],
    },
  };
  const local = {
    support: { total: 1, rows: [localConv('l-high', '2026-09-10T10:00:00Z', { triage_priority: 2.7, triage_label: 'legal_review' })] },
    personal: { total: 1, rows: [localConv('l-personal', '2026-09-10T10:00:00Z')] },
  };
  const labels = { local: [{ slug: 'legal_review', name: 'Mine legal' }], org: [{ slug: 'legal_review', name: 'Org legal' }] };

  it('Mine merges MX + local rows by priority, then newest, with chips', () => {
    const personal = personalCells([{ slug: 'personal', name: 'Personal' }], spaces);
    const { cells, rowsBySlug } = buildBoard({ view: BOARD_VIEW.MINE, metric: BOARD_METRIC.OPEN, spaces, personal, mx, local, labels });

    expect(cells.map((c) => c.id)).toEqual(['support', 'personal', 'triage']); // holding pen last
    expect(cells[0].open).toBe(3); // MX total + local total
    expect(cells[0].unassigned).toBeNull(); // not a Mine notion
    expect(cells[2].open).toBe(0); // no MX result yet → nothing, not the org stat

    const rows = rowsBySlug.support;
    expect(rows.map((r) => r.id)).toEqual(['m-urgent', 'l-high', 'm-new']);
    expect(rows[0].priorityChip).toEqual({ badge: 'Urgent', tone: 'urgent' });
    expect(rows[1].priorityChip).toEqual({ badge: 'High', tone: 'pending' });
    expect(rows[2].priorityChip).toBeNull();
    // Custom label names come from the row's own source list.
    expect(rows[0].labelChip.badge).toBe('Org legal');
    expect(rows[1].labelChip.badge).toBe('Mine legal');
    expect(rows[1].accountKey).toBe('acc_1');
    expect(rows[2].labelChip).toEqual({ badge: 'Reply', tone: 'urgent' });
    expect(rows[2].assignees).toEqual([]); // avatars are a Team-board thing
    expect(rowsBySlug.personal.map((r) => r.id)).toEqual(['l-personal']);
  });

  it('Team is MX only: no local rows, no personal cells, assignees kept', () => {
    const personal = personalCells([{ slug: 'personal', name: 'Personal' }], spaces);
    const { cells, rowsBySlug } = buildBoard({ view: BOARD_VIEW.TEAM, metric: BOARD_METRIC.OPEN, spaces, personal, mx, local, labels });

    expect(cells.map((c) => c.id)).toEqual(['support', 'triage']);
    expect(cells[0].open).toBe(2);
    expect(cells[0].unassigned).toBe(4);
    expect(cells[1].open).toBe(1); // before its fetch lands: the Space's own stat
    expect(rowsBySlug.support.map((r) => r.id)).toEqual(['m-urgent', 'm-new']);
    expect(rowsBySlug.support[1].assignees).toEqual([{ id: 'mem_1', name: 'Maya' }]);
  });
});

describe('personalCells', () => {
  it('skips slugs an org Space owns and invalid entries', () => {
    const cells = personalCells([{ slug: 'support' }, { slug: 'reading', name: 'Reading' }, null, {}], spaces);
    expect(cells.map((c) => c.id)).toEqual(['reading']);
    expect(cells[0].openness).toBe('personal');
  });
});

describe('metric filters', () => {
  it('All items never includes trash or spam', () => {
    expect(mxQuery(BOARD_METRIC.ALL).status).not.toContain('trash');
    expect(mxQuery(BOARD_METRIC.ALL).status).not.toContain('spam');
    // All items = inbox + archive, never trash/spam.
    expect(localWhere(BOARD_METRIC.ALL)).toContain("c.status NOT IN ('trash', 'spam')");
    expect(localWhere(BOARD_METRIC.ALL)).toContain("c.status = 'archived' OR");
    // Open = really in an inbox folder, not just status open.
    expect(localWhere(BOARD_METRIC.OPEN)).toContain("f.well_known_role = 'inbox'");
  });

  it('Unread is open and unread', () => {
    expect(mxQuery(BOARD_METRIC.UNREAD)).toEqual({ status: 'open', read: 'false' });
    expect(localWhere(BOARD_METRIC.UNREAD)).toContain('c.read = 0');
    expect(localWhere(BOARD_METRIC.UNREAD)).toContain("'archived'");
  });
});

describe('space colors', () => {
  it('gives the six defaults and the personal Spaces distinct hues', () => {
    const slugs = ['support', 'sales', 'marketing', 'finance', 'operations', 'triage', 'personal', 'reading'];
    expect(new Set(slugs.map((s) => spaceColor(s).key)).size).toBe(slugs.length);
  });
});
