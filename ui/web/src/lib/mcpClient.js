// The outbound MCP client (docs/MCP-Client.md): IPC wrappers for the Tauri
// commands, plus the pure argument builders the Send-to dialog uses. Desktop
// only — the browser build has no Rust core to talk to.
import { isTauri } from './tauri';

async function call(cmd, args) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke(cmd, args);
}

export const mcpAvailable = () => isTauri();
export const listMcpPresets = () => call('mcp_presets');
export const listMcpConnections = () => call('mcp_list_connections');
export const addMcpConnection = ({ name, url, token, clientId, clientSecret }) =>
  call('mcp_add_connection', { name, url, token: token || null, clientId: clientId || null, clientSecret: clientSecret || null });
export const reauthMcpConnection = (id, token) => call('mcp_reauth_connection', { id, token: token || null });
export const removeMcpConnection = (id) => call('mcp_remove_connection', { id });
export const listMcpTools = (id) => call('mcp_list_tools', { id });
export const callMcpTool = (id, tool, args) => call('mcp_call_tool', { id, tool, arguments: args });
export const addLoreSent = (itemKey, connectionName, summary) =>
  call('lore_sent_add', { itemKey, connectionName, summary: summary || '' });
export const listLoreSent = () => call('lore_sent_list');
// Tells useLore that "Send to…" stored a new reference.
export const LORE_SENT_CHANGED = 'inbox2:lore-sent-changed';

// The core's error string for "sign in again" (mcp_client::NEEDS_AUTH).
export const NEEDS_AUTH = 'needs_auth';
export const MCP_STATUS = { CONNECTED: 'connected', NEEDS_AUTH: 'needs_auth', ERROR: 'error' };
export const MCP_AUTH = { OAUTH: 'oauth', TOKEN: 'token', NONE: 'none', CLIENT_ID: 'client_id' };

// Brand lookup domain for a server URL: mcp.linear.app → linear.app.
const BRAND_OVERRIDE = { 'githubcopilot.com': 'github.com' };
export function serverDomain(url) {
  let host;
  try { host = new URL(url).hostname; } catch { return null; }
  const bare = host.replace(/^(mcp|api)\./, '');
  return BRAND_OVERRIDE[bare] || bare;
}

export function sourceLine(item) {
  return `From inbox2: ${item.from || item.address || 'unknown sender'} — ${item.subject || '(no subject)'}`;
}

function body(item) {
  return [item.detail, sourceLine(item)].filter(Boolean).join('\n\n');
}

function splitName(from) {
  const parts = String(from || '').trim().split(/\s+/);
  return { first: parts[0] || '', last: parts.slice(1).join(' ') };
}

// Hand-written templates for known targets. Each returns candidate values;
// buildDefaults keeps only the keys the tool's schema actually has.
const TEMPLATES = [
  { host: /linear\.app$/, tool: /(create|save)_?issue/i,
    args: (it) => ({ title: it.subject, description: body(it) }) },
  { host: /github/, tool: /create_issue/i,
    args: (it) => ({ title: it.subject, body: body(it) }) },
  { host: /atlassian/, tool: /create.*jira.*issue|jira.*create.*issue/i,
    args: (it) => ({ summary: it.subject, description: body(it), issueTypeName: 'Task' }) },
  { host: /hubspot/, tool: /contact/i,
    args: (it) => {
      const { first, last } = splitName(it.from);
      const props = { email: it.address, firstname: first, lastname: last, company: it.domain };
      return { ...props, properties: props };
    } },
  { host: /hubspot/, tool: /note/i,
    args: (it) => ({ body: body(it), hs_note_body: body(it), properties: { hs_note_body: body(it) } }) },
  { host: /notion/, tool: /create.*page/i,
    args: (it) => ({
      pages: [{ properties: { title: it.subject }, content: body(it) }],
      title: it.subject, content: body(it),
    }) },
];

const TITLE_KEYS = ['title', 'name', 'summary', 'subject'];
const BODY_KEYS = ['description', 'body', 'content', 'text', 'notes', 'note', 'message', 'details'];

export function templateFor(url, toolName) {
  let host = '';
  try { host = new URL(url).hostname; } catch { /* no host, no template */ }
  return TEMPLATES.find((t) => t.host.test(host) && t.tool.test(toolName)) || null;
}

const isPrimitive = (p) => ['string', 'number', 'integer', 'boolean'].includes(p?.type) || Array.isArray(p?.enum);

/** The schema's fields in display order: required first. */
export function schemaFields(schema) {
  const props = schema?.properties || {};
  const required = new Set(schema?.required || []);
  return Object.entries(props)
    .map(([key, p]) => ({
      key,
      label: p.title || key,
      description: p.description || '',
      type: Array.isArray(p.enum) ? 'enum' : isPrimitive(p) ? p.type : 'json',
      options: p.enum || null,
      required: required.has(key),
    }))
    .sort((a, b) => Number(b.required) - Number(a.required));
}

/** Initial form values for a tool: template, else title/description guesses. */
export function buildDefaults(url, tool, item) {
  const fields = schemaFields(tool.input_schema);
  const tpl = templateFor(url, tool.name);
  const cand = tpl ? tpl.args(item) : {};
  const values = {};
  for (const f of fields) {
    let v = cand[f.key];
    if (v === undefined && !tpl) {
      const k = f.key.toLowerCase();
      if (TITLE_KEYS.includes(k)) v = item.subject;
      else if (BODY_KEYS.includes(k)) v = body(item);
    }
    if (v === undefined || v === null || v === '') { values[f.key] = f.type === 'boolean' ? false : ''; continue; }
    values[f.key] = f.type === 'json' ? JSON.stringify(v, null, 2) : v;
  }
  return values;
}

/** Form values → tool arguments. Throws on a bad JSON field. Drops empty optionals. */
export function buildArguments(tool, values) {
  const args = {};
  for (const f of schemaFields(tool.input_schema)) {
    const v = values[f.key];
    if (f.type === 'boolean') { if (v || f.required) args[f.key] = !!v; continue; }
    if (v === '' || v === undefined || v === null) continue;
    if (f.type === 'number' || f.type === 'integer') {
      const n = Number(v);
      if (Number.isNaN(n)) throw new Error(`${f.label} must be a number`);
      args[f.key] = f.type === 'integer' ? Math.trunc(n) : n;
    } else if (f.type === 'json') {
      try { args[f.key] = JSON.parse(v); } catch { throw new Error(`${f.label} is not valid JSON`); }
    } else {
      args[f.key] = v;
    }
  }
  return args;
}

export const missingRequired = (tool, values) =>
  schemaFields(tool.input_schema).filter((f) => f.required && f.type !== 'boolean' && String(values[f.key] ?? '').trim() === '');

/** Order tools so the ones that create something (and have a template) come first. */
export function rankTools(url, tools) {
  const score = (t) => (templateFor(url, t.name) ? 2 : 0) + (/create|add|new|save/i.test(t.name) ? 1 : 0);
  return [...tools].sort((a, b) => score(b) - score(a));
}

/** The first text block of a tool result — e.g. the created issue's URL. */
export function firstText(content) {
  const block = (Array.isArray(content) ? content : []).find((c) => c?.type === 'text' && c.text);
  return block ? String(block.text) : '';
}
