// @vitest-environment jsdom
//
// Smoke test: the filter UI must mount and survive a click. A throw here is
// what the app shows as its 500 page (ErrorBoundary), which is exactly how the
// first version of this shipped — the Filters button read e.currentTarget
// inside a state updater, by which time React had nulled it.
import { describe, it, expect, afterEach } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';
import SearchFilterChips from '../SearchFilterChips';
import SearchFilterPopover from '../SearchFilterPopover';
import { parse } from '../../../lib/searchQuery';

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const mounted = [];
function render(element) {
  const host = document.createElement('div');
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(element));
  mounted.push({ root, host });
  return host;
}

afterEach(() => {
  act(() => mounted.forEach(({ root }) => root.unmount()));
  mounted.length = 0;
  document.body.innerHTML = '';
});

const FILTER = parse('invoice from:ana has:attachment type:pdf in:trash larger:5mb after:2026-01-01');

describe('search filter UI', () => {
  it('renders a chip per active filter and removes one on click', () => {
    let latest = null;
    const host = render(createElement(SearchFilterChips, { filter: FILTER, onChange: (q) => { latest = q; } }));

    const chips = host.querySelectorAll('button');
    // 6 filters + the "Clear filters" link.
    expect(chips.length).toBe(7);
    expect(host.textContent).toContain('from: ana');
    expect(host.textContent).toContain('larger than 5mb');

    act(() => chips[0].click());
    expect(latest.from).toEqual([]);
  });

  it('renders nothing when no filter is set', () => {
    const host = render(createElement(SearchFilterChips, { filter: parse('just words'), onChange: () => {} }));
    expect(host.textContent).toBe('');
  });

  it('mounts the dialog open with every group', () => {
    render(createElement(SearchFilterPopover, {
      open: true,
      filter: FILTER,
      onChange: () => {},
      onClose: () => {},
    }));

    // Portals to body, so assert on the document rather than the host.
    for (const group of ['People', 'Attachments', 'State', 'Where', 'When']) {
      expect(document.body.textContent).toContain(group);
    }
    // The footer echoes the operator string the dialog would write.
    expect(document.body.textContent).toContain('from:ana');
  });

  // Tabs carry a count badge in the same button, so match on the leading text.
  const byText = (label) =>
    [...document.querySelectorAll('button')].find(b => b.textContent.trim().startsWith(label));

  it('starts on People and swaps the panel for Attachments', () => {
    render(createElement(SearchFilterPopover, {
      open: true, filter: FILTER, onChange: () => {}, onClose: () => {},
    }));

    expect(document.body.textContent).toContain('Subject');
    expect(document.body.textContent).not.toContain('Larger than');

    act(() => byText('Attachments').click());
    expect(document.body.textContent).toContain('Larger than');
    expect(document.body.textContent).not.toContain('Subject');
  });

  it('locks "has an attachment" on when a file filter already implies it', () => {
    render(createElement(SearchFilterPopover, {
      open: true, filter: parse('report type:docx'), onChange: () => {}, onClose: () => {},
    }));
    act(() => byText('Attachments').click());

    const toggle = document.querySelector('#filter-has-attachment');
    expect(toggle.checked).toBe(true);
    expect(toggle.disabled).toBe(true);
    expect(document.body.textContent).toContain('The filters above already need one');
  });

  it('leaves "has an attachment" free when nothing implies it', () => {
    render(createElement(SearchFilterPopover, {
      open: true, filter: parse('report'), onChange: () => {}, onClose: () => {},
    }));
    act(() => byText('Attachments').click());

    const toggle = document.querySelector('#filter-has-attachment');
    expect(toggle.checked).toBe(false);
    expect(toggle.disabled).toBe(false);
  });

  it('leaves the date fields empty when the query has no dates', () => {
    render(createElement(SearchFilterPopover, {
      open: true, filter: parse('hetzner'), onChange: () => {}, onClose: () => {},
    }));

    const dates = [...document.querySelectorAll('input')]
      .filter(i => i.placeholder === 'yyyy-mm-dd');
    expect(dates).toHaveLength(2);
    // Never seeded with today — an untouched field is not a filter.
    for (const input of dates) expect(input.value).toBe('');
  });

  it('edits a draft and only commits on Apply', () => {
    let latest = null;
    let closed = false;
    render(createElement(SearchFilterPopover, {
      open: true,
      filter: FILTER,
      onChange: (q) => { latest = q; },
      onClose: () => { closed = true; },
    }));

    // A half-built filter must not re-run the search behind the dialog.
    act(() => byText('Unread').click());
    expect(latest).toBeNull();

    act(() => byText('Apply').click());
    expect(latest.is).toContain('unread');
    expect(latest.from).toEqual(['ana']);
    expect(latest.text).toBe('invoice');
    expect(closed).toBe(true);
  });

  it('Cancel leaves the query untouched', () => {
    let latest = null;
    render(createElement(SearchFilterPopover, {
      open: true,
      filter: FILTER,
      onChange: (q) => { latest = q; },
      onClose: () => {},
    }));

    act(() => byText('Unread').click());
    act(() => byText('Cancel').click());
    expect(latest).toBeNull();
  });

  it('Clear commits the cleared query and closes, keeping the words', () => {
    let latest = null;
    let closed = false;
    render(createElement(SearchFilterPopover, {
      open: true,
      filter: FILTER,
      onChange: (q) => { latest = q; },
      onClose: () => { closed = true; },
    }));

    act(() => byText('Clear').click());
    expect(latest.text).toBe('invoice');
    expect(latest.from).toEqual([]);
    expect(latest.in).toBeNull();
    expect(latest.larger).toBeNull();
    expect(closed).toBe(true);
  });
});
