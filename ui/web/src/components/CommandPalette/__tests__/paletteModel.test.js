import { describe, it, expect } from 'vitest';
import { buildSections } from '../paletteModel';

const CMDS = [
  { id: 'inbox', group: 'Navigate', label: 'Go to Inbox' },
  { id: 'calendar', group: 'Navigate', label: 'Go to Calendar' },
  { id: 'compose', group: 'Actions', label: 'Compose new message' },
  { id: 'theme', group: 'View', label: 'Switch to light mode', keywords: 'dark appearance' },
];

const flat = (sections) => sections.flatMap(s => s.items);

describe('buildSections', () => {
  it('groups unfiltered commands and drops empty sections', () => {
    const sections = buildSections(CMDS, '', []);
    expect(sections.map(s => s.title)).toEqual(['Navigate', 'Actions', 'View']);
  });

  it('pins recents on top without duplicating them in their own group', () => {
    const sections = buildSections(CMDS, '', ['compose']);
    expect(sections[0].title).toBe('Recent');
    expect(sections[0].items.map(c => c.id)).toEqual(['compose']);
    expect(flat(sections).filter(c => c.id === 'compose')).toHaveLength(1);
    expect(sections.find(s => s.title === 'Actions')).toBeUndefined();
  });

  it('numbers items continuously across sections for keyboard nav', () => {
    expect(flat(buildSections(CMDS, '', ['theme'])).map(c => c.index)).toEqual([0, 1, 2, 3]);
  });

  it('fuzzy-filters into one ranked flat list with match positions', () => {
    const sections = buildSections(CMDS, 'gtc', []);
    expect(sections).toHaveLength(1);
    expect(sections[0].title).toBeNull();
    expect(sections[0].items.map(c => c.id)).toEqual(['calendar']);
    expect(sections[0].items[0].indices.length).toBe(3);
  });

  it('breaks score ties by recency', () => {
    const [first] = buildSections(CMDS, 'go to', ['calendar'])[0].items;
    expect(first.id).toBe('calendar');
  });

  it('matches on keywords, ranked below every label match', () => {
    const items = buildSections(CMDS, 'dark', [])[0].items;
    expect(items.map(c => c.id)).toEqual(['theme']);
    expect(items[0].indices).toEqual([]); // no highlight — the query isn't in the label
  });

  it('keeps a label match ahead of a keyword match on the same query', () => {
    const cmds = [...CMDS, { id: 'dark-doc', group: 'View', label: 'Dark mode docs' }];
    expect(buildSections(cmds, 'dark', [])[0].items.map(c => c.id)).toEqual(['dark-doc', 'theme']);
  });

  it('offers the fallback command when nothing matches', () => {
    const fallback = { id: 'search-query', label: 'Search for zzz' };
    expect(buildSections(CMDS, 'zzz', [], fallback)[0].items.map(c => c.id)).toEqual(['search-query']);
    expect(buildSections(CMDS, 'go', [], fallback)[0].items.map(c => c.id)).not.toContain('search-query');
  });

  it('returns nothing when no command matches and there is no fallback', () => {
    expect(buildSections(CMDS, 'zzz', [])).toEqual([]);
  });
});
