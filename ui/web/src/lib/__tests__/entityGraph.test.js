import { describe, it, expect } from 'vitest';
import { mergeEntityGraphs, entityKey } from '../entityGraph';

describe('mergeEntityGraphs', () => {
  it('merges the same org/person across sources and remaps links', () => {
    const mx = {
      nodes: [
        { id: 'ent_a', kind: 'organization', name: 'Acme', email_domain: 'acme.com', weight: 3 },
        { id: 'ent_b', kind: 'person', name: 'Jane', address: 'jane@acme.com', email_domain: 'acme.com', weight: 2 },
      ],
      links: [{ source: 'ent_b', target: 'ent_a', label: 'works_at', weight: 2 }],
    };
    const local = {
      nodes: [
        { id: 'ent_x', kind: 'organization', name: 'Acme', email_domain: 'acme.com', weight: 1 },
        { id: 'ent_y', kind: 'person', name: 'Jane Doe', address: 'Jane@acme.com', weight: 1 },
        { id: 'ent_z', kind: 'project', name: 'VAT rewrite', weight: 1 },
      ],
      links: [
        { source: 'ent_y', target: 'ent_x', label: 'works_at', weight: 1 },
        { source: 'ent_z', target: 'ent_gone', label: 'about', weight: 1 },
      ],
    };
    const g = mergeEntityGraphs([mx, null, local]);
    expect(g.nodes).toHaveLength(3);
    const acme = g.nodes.find(n => n.id === entityKey(mx.nodes[0]));
    expect(acme).toMatchObject({ type: 'entity', weight: 4, total: 4 });
    expect(g.nodes.find(n => n.kind === 'person')).toMatchObject({ name: 'Jane Doe', weight: 3 });
    expect(g.links).toEqual([
      { source: 'person:jane@acme.com', target: 'organization:acme.com', label: 'works_at', weight: 3, kind: 'internal' },
    ]);
  });
});
