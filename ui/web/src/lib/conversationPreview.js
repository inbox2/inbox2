// The one line of body text shown next to the subject in a list row.
//
// Prefers the triage worker's generated one-liner (`ai_summary_short`) once it
// exists, falling back to the raw body snippet until then — so a row starts with
// the snippet and upgrades in place when triage lands.
//
// The catch: the deterministic (no-model / marketing-rule) triage path writes the
// SUBJECT as `short` (see `deterministic_summaries` in ai_worker.rs), which would
// render as "Subject — Subject". Those echoes fall back to the snippet.
export function conversationPreview(conv) {
  const summary = (conv.ai_summary_short || '').trim().replace(/…$/, '');
  const subject = (conv.subject || '').trim();
  if (summary && !subject.toLowerCase().startsWith(summary.toLowerCase())) return summary;
  return conv.snippet || '';
}
