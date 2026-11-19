import { describe, it, expect } from 'vitest';
import { resolveWorkspace, defaultDomainOf } from '../workspace';

// An org owns many equal domains; the primary domain's slug equals the org slug.
const orgs = [
  {
    id: 'org_1',
    slug: 'inbox2-com',
    domain: 'inbox2.com',
    domains: [
      { id: 'dom_a', name: 'inbox2.com', slug: 'inbox2-com' },
      { id: 'dom_b', name: 'ilabexperiment.xyz', slug: 'ilabexperiment-xyz' },
      { id: 'dom_c', name: 'messy.sh', slug: 'messy-sh' },
    ],
  },
  {
    id: 'org_2',
    slug: 'other-co',
    domain: 'other.co',
    domains: [{ id: 'dom_d', name: 'other.co', slug: 'other-co' }],
  },
];

describe('resolveWorkspace', () => {
  it('resolves a non-primary domain slug to its org + domain', () => {
    const { org, domain } = resolveWorkspace(orgs, 'ilabexperiment-xyz');
    expect(org?.id).toBe('org_1');
    expect(domain?.id).toBe('dom_b');
  });

  it('when the org slug coincides with the default domain slug, the domain match wins', () => {
    // org_1 is named after its domain, so slug `inbox2-com` is BOTH → the specific
    // domain view wins (there is still the unified /:orgSlug/mail for "everything").
    const { org, domain } = resolveWorkspace(orgs, 'inbox2-com');
    expect(org?.id).toBe('org_1');
    expect(domain?.id).toBe('dom_a');
  });

  it('resolves by org public id (org-level, domain=null)', () => {
    const { org, domain } = resolveWorkspace(orgs, 'org_2');
    expect(org?.id).toBe('org_2');
    expect(domain).toBeNull();
  });

  it('when the org slug differs from the default domain slug, the org slug stays org-level', () => {
    // Mirrors the seed: org "Acme Corp" (slug acme-corp) with default domain acme.com.
    const acme = [{
      id: 'org_a', slug: 'acme-corp', domain: 'acme.com',
      domains: [
        { id: 'dom_1', name: 'acme.com', slug: 'acme-com' },
        { id: 'dom_2', name: 'widgets.co', slug: 'widgets-co' },
      ],
    }];
    expect(resolveWorkspace(acme, 'acme-corp').domain).toBeNull();          // org-wide
    expect(resolveWorkspace(acme, 'acme-com').domain?.id).toBe('dom_1');    // acme.com only
    expect(resolveWorkspace(acme, 'widgets-co').domain?.id).toBe('dom_2');  // widgets.co only
    expect(defaultDomainOf(resolveWorkspace(acme, 'acme-corp').org)?.id).toBe('dom_1');
  });

  it('does not cross orgs — a slug only matches its owning org', () => {
    const { org, domain } = resolveWorkspace(orgs, 'messy-sh');
    expect(org?.id).toBe('org_1');
    expect(domain?.id).toBe('dom_c');
  });

  it('returns nulls for an unknown or empty slug', () => {
    expect(resolveWorkspace(orgs, 'nope')).toEqual({ org: null, domain: null });
    expect(resolveWorkspace(orgs, '')).toEqual({ org: null, domain: null });
    expect(resolveWorkspace(null, 'inbox2-com')).toEqual({ org: null, domain: null });
  });

  it('handles a legacy org with no domains array', () => {
    const legacy = [{ id: 'org_x', slug: 'legacy-co', domain: 'legacy.co' }];
    const { org, domain } = resolveWorkspace(legacy, 'legacy-co');
    expect(org?.id).toBe('org_x');
    expect(domain).toBeNull();
  });
});
