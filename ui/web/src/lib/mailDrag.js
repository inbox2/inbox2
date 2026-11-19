// Mail as files: an attachment as its own file for dragging out of the window
// (lib/dragOut.js; from the per-message attachment cache, downloading it first
// if needed), and a whole message exported as a .eml (the message menu).
import { invoke } from '@tauri-apps/api/core';
import { isMxAttachment, mxAttachmentBytes, browserSave } from './mxAttachments';
import { isTauri } from './tauri';
import { resolveAccountKey } from './draftAttachments';

/**
 * An attachment → the absolute path of its file on this Mac, or null when it
 * isn't there yet. Nothing is downloaded for a drag: opening the attachment
 * (or Save as / Forward) puts it in the per-message cache, and from then on it
 * drags. MX attachments share that cache under the 'mx' key, as Open does.
 */
export async function cachedAttachmentFile(attachment, message) {
  const messageKey = message?.key || message?.id;
  const filename = attachment.name || attachment.filename || 'attachment';
  const accountKey = isMxAttachment(attachment) ? 'mx' : await resolveAccountKey(message);
  if (!accountKey || !messageKey) return null;
  return invoke('attachment_cache_path', { accountKey, messageKey, filename });
}

// A MIME parameter (filename, name): quoted with " and \ escaped when ASCII,
// RFC 2231 (`key*=UTF-8''…`) when not.
export function param(key, value) {
  const v = String(value || '');
  return /^[\x20-\x7e]*$/.test(v)
    ? `${key}="${v.replace(/["\\]/g, '\\$&')}"`
    : `${key}*=UTF-8''${encodeURIComponent(v).replace(/['()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)}`;
}

const ASCII = /^[\x20-\x7e]*$/;

// RFC 2047 for text with anything beyond ASCII: encoded words of at most 45
// UTF-8 bytes each (75 chars encoded), never splitting a character, joined by
// folding whitespace.
export function encodeWords(text) {
  if (ASCII.test(text)) return text;
  const words = [];
  let chunk = '';
  for (const ch of text) {
    if (new TextEncoder().encode(chunk + ch).length > 45) { words.push(chunk); chunk = ''; }
    chunk += ch;
  }
  if (chunk) words.push(chunk);
  return words.map((w) => `=?UTF-8?B?${b64(w)}?=`).join('\r\n ');
}
const header = encodeWords;

// An address list ("José <j@example.com>, Ann <a@b.nl>"): only display names are
// encoded, so every address stays readable to mail parsers; long lists fold.
export function addressHeader(value) {
  const parts = String(value || '').split(/,(?=(?:[^"]*"[^"]*")*[^"]*$)/).map((p) => p.trim()).filter(Boolean);
  return parts.map((p) => {
    const m = p.match(/^(.*?)\s*<([^>]+)>$/);
    if (!m) return p;
    const name = m[1].replace(/^"(.*)"$/, '$1').trim();
    if (!name) return `<${m[2]}>`;
    return `${ASCII.test(name) ? `"${name.replace(/["\\]/g, '\\$&')}"` : encodeWords(name)} <${m[2]}>`;
  }).join(',\r\n ');
}
function b64(text) {
  const bytes = new TextEncoder().encode(text);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
const wrap76 = (s) => s.replace(/.{1,76}/g, '$&\r\n');

/**
 * An MX message (no raw MIME is kept server-side) as RFC 822 text: its headers,
 * plain + HTML bodies, and `files` ([{ name, type, bytes }]) as attachment parts.
 */
export function buildEml(m, files = []) {
  const date = m.created_at ? new Date(m.created_at).toUTCString().replace('GMT', '+0000') : new Date().toUTCString();
  const lines = [
    `From: ${addressHeader(m.from_address || '')}`,
    m.to_address && `To: ${addressHeader(m.to_address)}`,
    m.cc_address && `Cc: ${addressHeader(m.cc_address)}`,
    m.bcc_address && `Bcc: ${addressHeader(m.bcc_address)}`,
    `Subject: ${header(m.subject || '')}`,
    `Date: ${date}`,
    messageId(m) && `Message-ID: ${messageId(m).startsWith('<') ? messageId(m) : `<${messageId(m)}>`}`,
    'MIME-Version: 1.0',
  ].filter(Boolean);
  const parts = [
    m.body_plain && ['text/plain', m.body_plain],
    m.body_html && ['text/html', m.body_html],
  ].filter(Boolean);
  const textPart = (type, text) => [`Content-Type: ${type}; charset=UTF-8`, 'Content-Transfer-Encoding: base64', '', wrap76(b64(text))].join('\r\n');
  const boundary = (n) => `inbox2-${n}-${Math.random().toString(36).slice(2)}`;
  // The body: one text part, or both as multipart/alternative.
  let body;
  if (parts.length <= 1) {
    const [type, text] = parts[0] || ['text/plain', ''];
    body = textPart(type, text);
  } else {
    const alt = boundary('alt');
    body = [`Content-Type: multipart/alternative; boundary="${alt}"`, '',
      ...parts.map(([type, text]) => `--${alt}\r\n${textPart(type, text)}`), `--${alt}--`, ''].join('\r\n');
  }
  if (!files.length) return [...lines, body].join('\r\n');
  // With attachments: multipart/mixed around the body and each file.
  const mixed = boundary('mix');
  const fileParts = files.map((f) => [
    `--${mixed}`,
    `Content-Type: ${f.type || 'application/octet-stream'}; ${param('name', f.name)}`,
    'Content-Transfer-Encoding: base64',
    `Content-Disposition: attachment; ${param('filename', f.name)}`,
    '',
    wrap76(bytesB64(f.bytes)),
  ].join('\r\n'));
  return [...lines, `Content-Type: multipart/mixed; boundary="${mixed}"`, '', `--${mixed}`, body, ...fileParts, `--${mixed}--`, ''].join('\r\n');
}

function bytesB64(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// MX names it message_id; local messages, message_id_header.
const messageId = (m) => m.message_id || m.message_id_header || null;

/** The engine's local stand-in for a source (store `local_message_source`): no MIME headers. */
export const isLocalStandIn = (raw) => !/^(content-type|mime-version):/im.test(raw.split(/\r?\n\r?\n/)[0]);

/**
 * Export a message as a .eml: a save dialog on desktop, a download on web.
 * Local channels give their raw source (attachments included); MX is built
 * from the message (buildEml). Resolves to the saved path/name, or null when
 * the dialog was cancelled.
 */
export async function exportEml(message, { mx, attachments = [] }) {
  // Demo mode scrubs what's on screen, not the files behind it: an export would
  // carry the real message and attachments.
  const { isDemoMode } = await import('./demoData');
  if (isDemoMode()) throw new Error('Export is off while demo data is on');
  let data;
  if (mx) {
    // Each attachment's bytes (sealed ones decrypted), so the .eml is the whole message.
    const files = await Promise.all(attachments.filter(isMxAttachment).map(async (a) => ({
      name: a.name || 'attachment',
      type: a.mimeType,
      bytes: await mxAttachmentBytes(a, message),
    })));
    data = buildEml(message, files);
  } else {
    const accountKey = await resolveAccountKey(message);
    const { getMessageSource, downloadAttachmentBytes } = await import('./providers/index.js');
    const src = await getMessageSource(accountKey || null, message.key || message.id);
    data = typeof src === 'string' ? src : src?.raw;
    if (!data) throw new Error('No source for this message');
    // When the provider can't give its raw source, the engine answers with a
    // local stand-in: headers and one body, no MIME structure, no attachments.
    // Rebuild that one from the message with its attachments' bytes instead.
    if (isLocalStandIn(data) && attachments.length) {
      if (!accountKey) throw new Error('No account for this message');
      const files = await Promise.all(attachments.map(async (a) => ({
        name: a.name || a.filename || 'attachment',
        type: a.mimeType,
        bytes: await downloadAttachmentBytes(accountKey, message.key || message.id, a),
      })));
      // The stand-in carries the Message-ID the local message object doesn't.
      const standInId = data.match(/^Message-ID:[ \t]*(\S.*)$/im)?.[1]?.trim() || null;
      data = buildEml({ ...message, message_id: messageId(message) || standInId }, files);
    }
  }
  const name = `${(message.subject || 'message').trim().replace(/[/\\:]/g, '-').slice(0, 100) || 'message'}.eml`;
  const bytes = new TextEncoder().encode(data);
  if (!isTauri()) {
    browserSave(bytes, name, 'message/rfc822');
    return name;
  }
  return invoke('save_attachment_as', { filename: name, data: Array.from(bytes) });
}
