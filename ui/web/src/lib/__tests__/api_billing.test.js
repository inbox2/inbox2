import { describe, it, expect, vi, afterEach } from 'vitest';
import api from '../api';

// Billing + domains are org-scoped under the inverted model.
describe('api org-scoped billing & domains', () => {
  afterEach(() => vi.restoreAllMocks());

  it('routes billing + domain calls under /orgs/:id', () => {
    const get = vi.spyOn(api, 'get').mockResolvedValue({});
    const post = vi.spyOn(api, 'post').mockResolvedValue({});
    const del = vi.spyOn(api, 'delete').mockResolvedValue({});

    api.getBilling('org_1');
    api.subscribe('org_1', 'plan_x');
    api.listDomains('org_1');
    api.addDomain('org_1', 'a.test');
    api.removeDomain('org_1', 'dom_9');

    expect(get).toHaveBeenCalledWith('/orgs/org_1/billing');
    // acknowledge is undefined for a plain (upgrade) subscribe.
    expect(post).toHaveBeenCalledWith('/orgs/org_1/billing/subscribe', { plan_id: 'plan_x', acknowledge: undefined });
    expect(get).toHaveBeenCalledWith('/orgs/org_1/domains');
    expect(post).toHaveBeenCalledWith('/orgs/org_1/domains', { domain: 'a.test' });
    expect(del).toHaveBeenCalledWith('/orgs/org_1/domains/dom_9');
  });

  it('passes acknowledge:true on an acknowledged downgrade', () => {
    const post = vi.spyOn(api, 'post').mockResolvedValue({});
    api.subscribe('org_1', 'plan_free', { acknowledge: true });
    expect(post).toHaveBeenCalledWith('/orgs/org_1/billing/subscribe', { plan_id: 'plan_free', acknowledge: true });
  });
});
