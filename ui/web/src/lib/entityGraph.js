// Merge Lore entity graphs (docs/Ontology.md) from several sources — one per MX
// org (GET /orgs/:id/lore/graph) plus the desktop's local channels
// (`lore_graph`) — into one force-graph dataset. The same organization or person
// seen in two sources is one node: people by address, organizations/products by
// domain, anything else by kind + name.

export const ENTITY_KINDS = ['organization', 'person', 'product', 'project'];

// Relation label → the link styles explorerPaint already knows.
const LINK_KIND = { works_at: 'internal' };

export function entityKey(n) {
  const byDomain = (n.kind === 'organization' || n.kind === 'product') && n.email_domain;
  return `${n.kind}:${(n.address || byDomain || n.name || '').toLowerCase()}`;
}

export function mergeEntityGraphs(graphs) {
  const nodes = new Map();
  const links = new Map();
  for (const g of graphs) {
    if (!g) continue;
    const idMap = new Map();
    for (const n of g.nodes || []) {
      const id = entityKey(n);
      idMap.set(n.id, id);
      const prev = nodes.get(id);
      if (prev) {
        prev.weight += n.weight || 0;
        prev.total = prev.weight;
        prev.email_domain = prev.email_domain || n.email_domain || null;
        // A real name ("Jane Doe") beats one guessed from the address ("Jane").
        if (n.name?.includes(' ') && !prev.name?.includes(' ')) prev.name = n.name;
      } else {
        nodes.set(id, {
          id, type: 'entity', kind: n.kind, name: n.name, address: n.address || null,
          email_domain: n.email_domain || null, weight: n.weight || 0, total: n.weight || 0,
        });
      }
    }
    for (const l of g.links || []) {
      const source = idMap.get(l.source);
      const target = idMap.get(l.target);
      if (!source || !target || source === target) continue;
      const key = `${source}→${target}→${l.label}`;
      const prev = links.get(key);
      if (prev) prev.weight += l.weight || 1;
      else links.set(key, { source, target, label: l.label, weight: l.weight || 1, kind: LINK_KIND[l.label] || 'shared_tag' });
    }
  }
  return { nodes: [...nodes.values()], links: [...links.values()] };
}
