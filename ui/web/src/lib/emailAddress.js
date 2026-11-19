// RFC 5322 email address parsing.
// Handles: "Display Name" <addr>, Display Name <addr>, <addr>, bare addr.

/**
 * Parse an RFC 5322 mailbox string into display name and email address.
 * @param {string} raw — e.g. '"John Doe" <john@example.com>'
 * @returns {{ name: string, email: string, explicit: boolean }} — `explicit`: the
 *   header supplied the name (false when it was derived from the address).
 */
export function parseAddress(raw) {
  if (!raw) return { name: '', email: '' };
  const str = raw.trim();

  // Case 1: "Display Name" <email> or Display Name <email>
  const angleBracket = str.lastIndexOf('<');
  if (angleBracket !== -1) {
    const closeBracket = str.indexOf('>', angleBracket);
    const email = str.slice(angleBracket + 1, closeBracket > angleBracket ? closeBracket : undefined).trim();
    let name = str.slice(0, angleBracket).trim();
    // Strip surrounding quotes (double or single)
    if ((name.startsWith('"') && name.endsWith('"')) ||
        (name.startsWith("'") && name.endsWith("'"))) {
      name = name.slice(1, -1).replace(/\\(.)/g, '$1');
    }
    name = cleanName(name);
    return { name: name || localToName(email), email, explicit: !!name };
  }

  // Case 2: bare email (no angle brackets)
  if (str.includes('@')) {
    return { name: localToName(str), email: str, explicit: false };
  }

  // Case 3: just a name (unusual but handle gracefully)
  let name = str;
  if ((name.startsWith('"') && name.endsWith('"')) ||
      (name.startsWith("'") && name.endsWith("'"))) {
    name = name.slice(1, -1);
  }
  return { name: cleanName(name), email: '', explicit: !!cleanName(name) };
}

/**
 * Strip HTML tags and collapse whitespace from a display name. Some senders
 * embed markup in the display name (e.g. an `<img onerror=…>` payload from
 * email-privacy testers); rendered raw it leaks ugly literal HTML into previews
 * and headers. A regex strip is enough here — names are short and this runs on
 * every row of a conversation list, so we avoid the DOM-based stripHtml.
 */
function cleanName(name) {
  return (name || '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
}

/**
 * Extract just the display name from an address string.
 */
export function displayName(raw) {
  return parseAddress(raw).name;
}

/**
 * Extract just the email from an address string.
 */
export function emailOnly(raw) {
  return parseAddress(raw).email;
}

/**
 * Parse an RFC 5322 address list (comma-separated mailboxes) into individual
 * { name, email } pairs. Handles commas inside quoted display names.
 * @param {string} raw — e.g. '"Doe, John" <john@ex.com>, Jane <jane@ex.com>'
 * @returns {{ name: string, email: string }[]}
 */
export function parseAddressList(raw) {
  if (!raw) return [];
  const str = raw.trim();
  if (!str) return [];

  // Split on commas that are NOT inside angle brackets or quotes.
  // Walk the string character-by-character to handle quoted commas.
  const parts = [];
  let current = '';
  let inQuote = false;
  let inAngle = false;

  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    if (ch === '\\' && inQuote && i + 1 < str.length) {
      // RFC 5322 quoted-pair (`\"`, `\\`) — formatMailbox emits these.
      current += ch + str[++i];
    } else if (ch === '"' && !inAngle) {
      inQuote = !inQuote;
      current += ch;
    } else if (ch === '<' && !inQuote) {
      inAngle = true;
      current += ch;
    } else if (ch === '>' && !inQuote) {
      inAngle = false;
      current += ch;
    } else if (ch === ',' && !inQuote && !inAngle) {
      const trimmed = current.trim();
      if (trimmed) parts.push(trimmed);
      current = '';
    } else {
      current += ch;
    }
  }
  const last = current.trim();
  if (last) parts.push(last);

  return parts.map(parseAddress).filter(a => a.email);
}

/**
 * Which of the user's own addresses a reply should come from. `fallback` is the
 * thread's own account (the page's default for it). A Gmail/Microsoft thread
 * always replies from that account — the send must go out on the transport that
 * owns the thread. An inbox2 thread picks among that org's inbox2 addresses: the one it
 * was sent from when it's your own mail, else the one it was sent to (To/Cc),
 * else `fallback`.
 * @param {{from_address?: string, to_address?: string, cc_address?: string}} msg
 * @param {Array<{email: string, providerType: string}>} identities — useFromIdentities()
 * @param {string} fallback
 * @returns {string}
 */
export function replyFromAddress(msg, identities, fallback) {
  const fb = (fallback || '').toLowerCase();
  const fbId = (identities || []).find(i => i.email.toLowerCase() === fb);
  if (fbId && fbId.providerType !== 'inbox2') return fallback;
  // Only the thread's own org's addresses — the send goes out through that org.
  const own = new Map((identities || [])
    .filter(i => i.providerType === 'inbox2' && (!fbId || i.orgId === fbId.orgId))
    .map(i => [i.email.toLowerCase(), i.email]));
  // From first: continuing your own sent mail keeps the address you sent it
  // from, even if another of your addresses is on To/Cc.
  for (const a of [
    ...parseAddressList(msg?.from_address),
    ...parseAddressList(msg?.to_address),
    ...parseAddressList(msg?.cc_address),
  ]) {
    const hit = own.get(a.email.toLowerCase());
    if (hit) return hit;
  }
  return fallback;
}

/**
 * The replier's addresses on `msg`: `self`, plus — when `self` appears nowhere
 * on the message and exactly one To/Cc address is on its domain — that address,
 * since the mail reached this mailbox through it (an alias like info@). Two or
 * more same-domain recipients are ambiguous (one may be a colleague): none is
 * dropped. The sender is never treated as self.
 * ponytail: heuristic, no Gmail send-as list; fetch send-as identities if it misfires.
 * @returns {Set<string>} lowercased
 */
export function ownAddresses(msg, self) {
  const me = emailOnly(self || '').toLowerCase();
  const own = new Set([me]);
  const emails = (...raws) => raws.flatMap(parseAddressList).map(a => a.email.toLowerCase());
  const rcpts = emails(msg?.to_address, msg?.cc_address);
  const at = me.indexOf('@');
  if (at < 0 || rcpts.includes(me) || emails(msg?.from_address).includes(me)) return own;
  const mine = [...new Set(rcpts.filter(e => e.endsWith(me.slice(at))))];
  if (mine.length === 1) own.add(mine[0]);
  return own;
}

/**
 * Reply-all recipients for a message, keeping the original To/Cc structure:
 * To = the sender + the original To line, Cc = the original Cc line — each minus
 * the replier's own address, de-duplicated by email (case-insensitive; an
 * address already on To is dropped from Cc), re-rendered as address lists. A raw
 * Set-of-header-strings can't strip self out of a multi-recipient To/Cc line.
 * @param {{from_address?: string, to_address?: string, cc_address?: string}} msg
 * @param {string} self — the account address to exclude
 * @returns {{to: string, cc: string}} — e.g. { to: 'Alice <a@x.com>, bob@y.com', cc: '' }
 */
export function replyAllRecipients(msg, self) {
  const seen = ownAddresses(msg, self);
  const render = (addrs) => addrs.flatMap(a => {
    const key = a.email.toLowerCase();
    if (!key || seen.has(key)) return [];
    seen.add(key);
    return [formatMailbox(a.name, a.email)];
  }).join(', ');
  const to = render([...parseAddressList(msg?.from_address), ...parseAddressList(msg?.to_address)]);
  const cc = render(parseAddressList(msg?.cc_address));
  return { to, cc };
}

/**
 * Render a recipient list (a `to`/`cc` address string) as a compact display
 * label for a conversation row — used by the Sent folder, where the row should
 * name who the mail was sent TO rather than the (self) sender. Shows the first
 * recipient's name and "+N" when there are more. Falls back to "(no recipient)".
 * @param {string} raw — an RFC 5322 address list, e.g. 'A <a@x>, B <b@y>'
 * @returns {string}
 */
export function recipientName(raw) {
  const list = parseAddressList(raw);
  if (list.length === 0) return '(no recipient)';
  const first = list[0].name || list[0].email;
  return list.length > 1 ? `${first} +${list.length - 1}` : first;
}

/** Derive a human-readable name from the local part of an email. */
/**
 * `Name <addr>` for the clipboard, the name RFC 5322-quoted when it holds
 * anything a mailbox list would split or misread (`"Doe, John" <j@x>`).
 */
export function formatMailbox(name, email) {
  if (!name) return email;
  // Atext + spaces only; anything else (comma, dot, quote, non-ASCII) gets quoted.
  const safe = /^[\w !#$%&'*+\-/=?^`{|}~]+$/.test(name);
  return `${safe ? name : `"${name.replace(/(["\\])/g, '\\$1')}"`} <${email}>`;
}

function localToName(email) {
  const local = (email || '').split('@')[0];
  if (!local) return '';
  return local.replace(/[._-]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}
