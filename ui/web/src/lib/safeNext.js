// Resolve a `?next=` post-auth return path safely. Only a local absolute path is
// allowed ("/console", "/link?…"); absolute/protocol-relative URLs ("//evil",
// "https://…") are rejected so the login/signup bounce can't become an open
// redirect. Returns null when there's no valid next.
export function safeNextPath(search) {
  const next = new URLSearchParams(search || '').get('next');
  return next && next.startsWith('/') && !next.startsWith('//') ? next : null;
}
