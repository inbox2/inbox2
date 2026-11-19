// The single sync-lifecycle event backbone. The Rust engine emits one `sync`
// bus event per phase; the frontend (indicator, refresh, console log, progress)
// all derive from it. See engine.rs `sync_event`.

export const SYNC_PHASE = {
  STARTED: 'started',
  FOLDER_STARTED: 'folder-started',
  FOLDER_PROGRESS: 'folder-progress',
  FOLDER_COMPLETE: 'folder-complete',
  COMPLETED: 'completed',
  FAILED: 'failed',
};

/** Phase marks the account as actively syncing (drives the "Syncing…" indicator). */
export function isSyncStart(p) {
  return p?.phase === SYNC_PHASE.STARTED;
}

/** Phase marks the account's sync as finished (success or failure). */
export function isSyncEnd(p) {
  return p?.phase === SYNC_PHASE.COMPLETED || p?.phase === SYNC_PHASE.FAILED;
}

/**
 * Phase indicates data actually changed, so list/detail views should refresh.
 * folder-progress always carries new messages; folder-complete only when it
 * synced something (a no-op incremental poll shouldn't trigger a refresh).
 */
export function isDataChange(p) {
  if (p?.phase === SYNC_PHASE.FOLDER_PROGRESS) return true;
  if (p?.phase === SYNC_PHASE.FOLDER_COMPLETE) {
    return (p.synced || 0) > 0 || (p.conversationKeys?.length || 0) > 0;
  }
  return false;
}

/**
 * Format a sync event into a Sync Console log line, or null to skip it.
 * @returns {{ level: string, message: string } | null}
 */
export function formatSyncLogLine(p) {
  const folder = p?.folderName || p?.folderKey;
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  switch (p?.phase) {
    case SYNC_PHASE.STARTED:
      return { level: 'INFO', message: 'Sync started' };
    case SYNC_PHASE.FOLDER_STARTED:
      return { level: 'INFO', message: `${folder}: starting…` };
    case SYNC_PHASE.FOLDER_PROGRESS: {
      // "INBOX: batch 3 +50 (250 total)" — monotonic running total per folder.
      const batch = p.batch != null ? `batch ${p.batch} ` : '';
      const added = p.added != null ? `+${p.added} ` : '';
      return { level: 'INFO', message: `${folder}: ${batch}${added}(${p.synced ?? 0} total)` };
    }
    case SYNC_PHASE.FOLDER_COMPLETE: {
      // Incremental syncs carry added/deleted; initial syncs carry a total.
      if (p.added != null || p.deleted != null) {
        const parts = [];
        if (p.added) parts.push(`${p.added} new`);
        if (p.deleted) parts.push(`${p.deleted} deleted`);
        const detail = parts.length ? parts.join(', ') : 'no changes';
        return { level: 'INFO', message: `${folder}: up to date (${detail})` };
      }
      return { level: 'INFO', message: `${folder}: done, ${plural(p.synced ?? 0, 'message')}` };
    }
    case SYNC_PHASE.COMPLETED: {
      // "Sync complete — 4 folders, 600 messages in 42s"
      const bits = [];
      if (p.folders != null) bits.push(plural(p.folders, 'folder'));
      if (p.messages != null) bits.push(plural(p.messages, 'message'));
      const summary = bits.length ? `: ${bits.join(', ')}` : '';
      const elapsed = p.elapsedSecs != null ? ` in ${p.elapsedSecs}s` : '';
      return { level: 'INFO', message: `Sync complete${summary}${elapsed}` };
    }
    case SYNC_PHASE.FAILED:
      return { level: 'ERROR', message: `Sync failed: ${p?.error || 'unknown error'}` };
    default:
      return null;
  }
}
