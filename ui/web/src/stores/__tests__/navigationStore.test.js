// @vitest-environment jsdom
//
// The trap this guards: search → settings → close settings (navigate(-1)) used to
// push a *second* search entry, so Back bounced between settings and search with
// no way out. A URL landing on a neighbouring entry must walk the stack.
import { describe, it, expect, beforeEach } from 'vitest';
import useNavigationStore from '../navigationStore';

const go = (url) => {
  window.history.pushState({}, '', url);
  const [pathname, search = ''] = url.split('?');
  return { pathname, search };
};

// Stand-in for routes.jsx parseUrl, trimmed to the pages this test walks.
const sync = (url) => {
  const { pathname, search } = go(url);
  const q = new URLSearchParams(search);
  if (/\/settings/.test(pathname)) return { page: 'settings', orgSlug: 'acme', accountKey: undefined, unified: false };
  if (/\/search/.test(pathname)) return { page: 'search', orgSlug: 'acme', accountKey: undefined, unified: false };
  return { page: 'mail', orgSlug: 'acme', accountKey: null, unified: true, conversationId: q.get('c') };
};

describe('navigationStore history', () => {
  let navigated;
  beforeEach(() => {
    navigated = [];
    go('/acme/mail');
    useNavigationStore.setState({
      page: 'mail', orgSlug: 'acme', accountKey: null, viewName: null, conversationId: null,
      unified: true, filterFrom: null, filterTo: null, space: null,
      stack: [], index: -1, _skipSyncCount: 0, _isRestoring: false,
      _navigate: (url) => { navigated.push(url); go(url); },
    });
  });

  it('escapes the search ↔ settings loop', () => {
    const s = () => useNavigationStore.getState();
    s().syncFromUrl(sync('/acme/mail'));
    s().syncFromUrl(sync('/acme/search?q=invoice'));
    s().syncFromUrl(sync('/acme/settings'));
    expect(s().stack.map(e => e.page)).toEqual(['mail', 'search', 'settings']);

    // Settings closes with navigate(-1): back onto search, no duplicate entry.
    s().syncFromUrl(sync('/acme/search?q=invoice'));
    expect(s().stack).toHaveLength(3);
    expect(s().index).toBe(1);

    // Clearing the search now leaves for mail instead of re-entering settings.
    s().goBack();
    expect(s().page).toBe('mail');
    expect(navigated).toEqual(['/acme/mail']);
  });

  it('restores a search entry to its own URL, query included', () => {
    const s = () => useNavigationStore.getState();
    s().syncFromUrl(sync('/acme/mail'));
    s().syncFromUrl(sync('/acme/search?q=invoice'));
    s().syncFromUrl(sync('/acme/settings'));
    s().goBack();
    expect(navigated).toEqual(['/acme/search?q=invoice']);
  });
});
