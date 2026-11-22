// Local-first API wrapper for Tauri desktop client.
//
// Wraps the standard api.js client: MX reads come from the engine's local mirror
// (lib/localData.js — instant, and they work offline), conversation actions go
// through the engine's durable queue (lib/mxMirror.js), and everything the mirror
// can't answer falls through to the API. See docs/MX-Sync.md.
// In browser mode, passes through directly to the remote API.
//
// Usage: import api from '../lib/localFirstApi';
//   (drop-in replacement for '../lib/api')
import remoteApi from './api.js';
import { isTauri } from './tauri.js';
import * as local from './localData.js';
import mxMirror from './mxMirror.js';
import { isDemoMode } from './demoData.js';

class LocalFirstApi {
  // Conversations — read from SQLite first, API as fallback/refresh
  async getConversations(orgId, params = {}) {
    const localResult = await local.getConversations(orgId, params);
    if (localResult) return localResult;
    return remoteApi.getConversations(orgId, params);
  }

  // Badge count — always server-side: unread badges are not something the mirror
  // opts into (docs/MX-Sync.md), so the server stays the one source of the count.
  getUnreadCount(orgId, params) { return remoteApi.getUnreadCount(orgId, params); }
  // Address folders — server-side only; the mirror has no folder tree.
  getFolders(orgId, domainKey) { return remoteApi.getFolders(orgId, domainKey); }
  updateFolderPrefs(orgId, prefs) { return remoteApi.updateFolderPrefs(orgId, prefs); }

  async getConversation(orgId, convId) {
    const localResult = await local.getConversation(orgId, convId);
    if (localResult) return localResult;
    return remoteApi.getConversation(orgId, convId);
  }

  updateConversation(orgId, convId, params) { return remoteApi.updateConversation(orgId, convId, params); }

  // Tags — local first
  async getTags(orgId) {
    const localResult = await local.getTags(orgId);
    if (localResult) return localResult;
    return remoteApi.getTags(orgId);
  }

  // Members — local first
  async getMembers(orgId) {
    const localResult = await local.getMembers(orgId);
    if (localResult) return localResult;
    return remoteApi.getMembers(orgId);
  }

  // Search — local first with LIKE, API fallback for full-text
  async search(orgId, query) {
    const localResult = await local.searchLocal(orgId, query);
    if (localResult) return localResult;
    return remoteApi.search(orgId, query);
  }

  // Everything else — pass through to remote API
  // (Auth, settings, billing, etc. don't need local-first)
  get(path) { return remoteApi.get(path); }
  post(path, body) { return remoteApi.post(path, body); }
  patch(path, body) { return remoteApi.patch(path, body); }
  put(path, body) { return remoteApi.put(path, body); }
  delete(path) { return remoteApi.delete(path); }

  // Auth
  get token() { return remoteApi.token; }
  setToken(t) { return remoteApi.setToken(t); }
  signup(p) { return remoteApi.signup(p); }
  login(p) { return remoteApi.login(p); }
  logout() { return remoteApi.logout(); }
  oauthProviders() { return remoteApi.oauthProviders(); }
  oauthCallback(p) { return remoteApi.oauthCallback(p); }
  resetPasswordRequest(e) { return remoteApi.resetPasswordRequest(e); }
  resetPassword(p) { return remoteApi.resetPassword(p); }
  acceptInvite(p) { return remoteApi.acceptInvite(p); }

  // Account
  getAccount() { return remoteApi.getAccount(); }

  // Organizations
  getOrg(orgId) { return remoteApi.getOrg(orgId); }
  getOrgDns(orgId) { return remoteApi.getOrgDns(orgId); }
  getOnboarding(orgId) { return remoteApi.getOnboarding(orgId); }

  // Views — always remote (UI config, not synced)
  getViews(orgId) { return remoteApi.getViews(orgId); }

  // Bulk conversation actions (archive / trash / spam / open / mark read+unread).
  //
  // Desktop, mirrored org: handed to the engine — applied to the local mirror
  // before this resolves, queued durably, and sent to the real bulk endpoint as
  // soon as the network allows (retrying on backoff). Offline is not a failure.
  // If the server REFUSES it, the engine gives the thread back to server state and
  // the list corrects itself on the next mirror change.
  //
  // This replaces the webview's own queue drain (mxWriteback.js): same table, now
  // owned by the engine, so mobile and the CLI get the same behaviour and a queued
  // action survives the window being closed.
  //
  // Browser, or an org not mirrored here: straight to the API; errors surface.
  async bulkConversations(orgId, ids, action) {
    const org = await local.mirroredOrg(orgId);
    if (!org) return remoteApi.bulkConversations(orgId, ids, action);
    // Demo mode: nothing may reach MX, and the mirror holds the real mail — so
    // nothing is written at all. The caller's optimistic UI still moves the row.
    if (isDemoMode()) return { success: true, _demo: true };
    await mxMirror.action(org, ids, action);
    return { success: true, _queued: true };
  }

  // Empty a disposable folder — MX/org-only, always server-side (offline channels
  // manage their own trash/spam via the provider, never through this path).
  emptyFolder(orgId, status) { return remoteApi.emptyFolder(orgId, status); }

  // Messages
  sendMessage(orgId, p) { return remoteApi.sendMessage(orgId, p); }
  getMessageRaw(orgId, c, m) { return remoteApi.getMessageRaw(orgId, c, m); }

  // Drafts
  getDrafts(orgId) { return remoteApi.getDrafts(orgId); }
  createDraft(orgId, p) { return remoteApi.createDraft(orgId, p); }
  updateDraft(orgId, id, p) { return remoteApi.updateDraft(orgId, id, p); }
  deleteDraft(orgId, id) { return remoteApi.deleteDraft(orgId, id); }

  // Notes
  createNote(orgId, convId, p) { return remoteApi.createNote(orgId, convId, p); }

  // Templates
  getTemplates(orgId) { return remoteApi.getTemplates(orgId); }

  // Notifications
  getNotifications() { return remoteApi.getNotifications(); }
  markNotificationsRead(ids) { return remoteApi.markNotificationsRead(ids); }

  // Plans & billing (org-scoped)
  getPlans() { return remoteApi.getPlans(); }
  getBilling(orgId) { return remoteApi.getBilling(orgId); }
  subscribe(orgId, planId, opts = {}) { return remoteApi.subscribe(orgId, planId, opts); }
  listDomains(orgId) { return remoteApi.listDomains(orgId); }
  addDomain(orgId, domain) { return remoteApi.addDomain(orgId, domain); }
  removeDomain(orgId, domainKey) { return remoteApi.removeDomain(orgId, domainKey); }

  // Mailboxes
  getMailboxStats(orgId) { return remoteApi.getMailboxStats(orgId); }
  getMailboxPair(orgId, source, target) { return remoteApi.getMailboxPair(orgId, source, target); }

  // Organization admin (Spaces dashboard create/invite) — always remote
  updateOrg(orgId, attrs) { return remoteApi.updateOrg(orgId, attrs); }
  createSpace(orgId, p) { return remoteApi.createSpace(orgId, p); }
  updateSpace(orgId, id, p) { return remoteApi.updateSpace(orgId, id, p); }
  deleteSpace(orgId, id) { return remoteApi.deleteSpace(orgId, id); }
  inviteMx(p) { return remoteApi.inviteMx(p); }
  getMemberFeed(orgId, memberKey) { return remoteApi.getMemberFeed(orgId, memberKey); }

  // Calendar (server-side MX calendar; the local mirror carries no events)
  listConferencing(orgId) { return remoteApi.listConferencing(orgId); }
  listBlockedTimes(orgId, start, end) { return remoteApi.listBlockedTimes(orgId, start, end); }
  createBlockedTime(orgId, p) { return remoteApi.createBlockedTime(orgId, p); }
  deleteBlockedTime(orgId, id) { return remoteApi.deleteBlockedTime(orgId, id); }
}

// Export the appropriate API based on environment
const api = isTauri() ? new LocalFirstApi() : remoteApi;
export default api;
