import { displayName } from '../../lib/emailAddress';
import { META_KIND } from '../../lib/providerTypes';

// Map a normalized social (Meta) conversation record to the props a
// SocialListRow expects. Pure (no JSX/CSS imports) so it can be unit tested in
// the node test env; ConversationList spreads the result. The email rows keep
// using conversationItemProps — this is the parallel mapper for chat channels.

// Meta sender identifiers can arrive as a handle ("@theo.makes") or a prefixed
// id ("whatsapp:1555…", "messenger:123"). Strip the "<surface>:" prefix and run
// it through displayName so a "Name <addr>" form still resolves.
function socialSender(conv) {
  const raw = conv.from_address || '';
  const stripped = raw.replace(/^(whatsapp|messenger|instagram|facebook|threads):/i, '');
  return displayName(stripped) || stripped || '(unknown)';
}

// Comment/mention snippets may carry a hand-authored "Comment: '…'" wrapper
// (demo seed) where real data is the bare comment text. The row shows a kind
// badge instead, so unwrap the prefix to avoid "💬 Comment: '…'" doubling up.
function cleanPreview(conv) {
  const s = conv.snippet || '';
  if (conv.kind === META_KIND.COMMENT || conv.kind === META_KIND.MENTION) {
    const m = s.match(/^Comment:\s*'(.*)'\s*$/);
    if (m) return m[1];
  }
  return s;
}

export function socialRowProps(conv) {
  return {
    sender: socialSender(conv),
    avatar: conv.from_avatar || null,
    handle: conv.from_address || '',
    channel: conv.channel || conv.providerType || null,
    providerType: conv.providerType || null,
    kind: conv.kind || META_KIND.DM,
    preview: cleanPreview(conv),
    time: new Date(conv.updated_at || conv.created_at).toLocaleDateString(),
    unread: !conv.read,
    count: conv.message_count || 1,
  };
}
