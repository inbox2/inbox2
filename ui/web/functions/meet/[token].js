// Cloudflare Pages Function for /meet/:token (docs/Calendar.md "Link previews").
// The SPA shell is the same for every route, so a shared meet link unfurled in
// WhatsApp/Slack/Mail used to read "Inbox2" with no name. This fetches the
// link's public payload and writes the person's name, meeting length and
// avatar into the shell's <head>. Any failure serves the plain shell.
/* global HTMLRewriter -- Cloudflare Workers runtime */
import { meetPreview } from '../../src/lib/meetPreview.js';

const API = 'https://api.inbox2.com/api/v1';

export async function onRequest(context) {
  const { request, params, next } = context;
  const page = await next();
  const token = String(params.token || '');
  if (!/^[\w-]{8,64}$/.test(token) || !(page.headers.get('content-type') || '').includes('text/html')) return page;

  let meet = null;
  try {
    // preview=1: an unfurl is not a visit, so it doesn't bump the link's stats.
    const res = await fetch(`${API}/meet/${token}?preview=1`, {
      headers: { accept: 'application/json' },
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    if (res.ok) meet = (await res.json())?.meet || null;
  } catch { /* API down — plain shell */ }

  const url = new URL(request.url);
  const rewriter = new HTMLRewriter()
    // A capability URL: never in a search index, previewed or not.
    .on('head', { element: (el) => el.append('<meta name="robots" content="noindex, nofollow" />', { html: true }) });
  if (meet) {
    const { title, html } = meetPreview(meet, `${url.origin}${url.pathname}`, `${url.origin}/favicon-512.png`);
    rewriter
      .on('title', { element: (el) => el.setInnerContent(title) })
      .on('head', { element: (el) => el.append(html, { html: true }) });
  }
  return rewriter.transform(page);
}
