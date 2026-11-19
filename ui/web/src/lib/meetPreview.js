// Link-preview (Open Graph) tags for a public meet page (docs/Calendar.md).
// Used by the Cloudflare Pages Function at functions/meet/[token].js — chat
// apps and mail clients never run the SPA, so the tags must be in the HTML.
// Pure: takes the public meet payload (GET /api/v1/meet/:token), returns HTML.

const esc = (s) => String(s ?? '')
  .replace(/&/g, '&amp;').replace(/"/g, '&quot;')
  .replace(/</g, '&lt;').replace(/>/g, '&gt;');

export function meetPreview(meet, pageUrl, fallbackImage) {
  const name = meet?.invitee?.name || 'the organizer';
  const title = `Meet with ${name}`;
  const org = meet?.organization ? ` · ${meet.organization}` : '';
  const description = `Pick a time for a ${meet?.duration_minutes || 30}-minute meeting${org}. `
    + `${name.split(' ')[0]} confirms every request.`;
  const image = meet?.invitee?.avatar_url || fallbackImage;
  const tags = [
    ['property', 'og:type', 'website'],
    ['property', 'og:site_name', 'inbox2'],
    ['property', 'og:title', title],
    ['property', 'og:description', description],
    ['property', 'og:url', pageUrl],
    ['property', 'og:image', image],
    ['name', 'twitter:card', 'summary'],
    ['name', 'twitter:title', title],
    ['name', 'twitter:description', description],
    ['name', 'twitter:image', image],
    ['name', 'description', description],
  ];
  return {
    title,
    html: tags.map(([attr, key, value]) => `<meta ${attr}="${key}" content="${esc(value)}" />`).join('\n'),
  };
}
