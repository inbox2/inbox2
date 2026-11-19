import { describe, it, expect } from 'vitest';
import {
  SYNC_PHASE,
  isSyncStart,
  isSyncEnd,
  isDataChange,
  formatSyncLogLine,
} from '../syncEvents';

describe('isSyncStart / isSyncEnd', () => {
  it('marks started as a start and completed/failed as ends', () => {
    expect(isSyncStart({ phase: SYNC_PHASE.STARTED })).toBe(true);
    expect(isSyncStart({ phase: SYNC_PHASE.FOLDER_PROGRESS })).toBe(false);
    expect(isSyncEnd({ phase: SYNC_PHASE.COMPLETED })).toBe(true);
    expect(isSyncEnd({ phase: SYNC_PHASE.FAILED })).toBe(true);
    expect(isSyncEnd({ phase: SYNC_PHASE.STARTED })).toBe(false);
  });

  it('is null-safe', () => {
    expect(isSyncStart(null)).toBe(false);
    expect(isSyncEnd(undefined)).toBe(false);
  });
});

describe('isDataChange', () => {
  it('treats folder-progress as a data change', () => {
    expect(isDataChange({ phase: SYNC_PHASE.FOLDER_PROGRESS })).toBe(true);
  });

  it('treats folder-complete as a change only when something synced', () => {
    expect(isDataChange({ phase: SYNC_PHASE.FOLDER_COMPLETE, synced: 5 })).toBe(true);
    expect(isDataChange({ phase: SYNC_PHASE.FOLDER_COMPLETE, synced: 0, conversationKeys: ['c1'] })).toBe(true);
    // no-op incremental poll → no refresh
    expect(isDataChange({ phase: SYNC_PHASE.FOLDER_COMPLETE, synced: 0, conversationKeys: [] })).toBe(false);
  });

  it('ignores lifecycle phases (started/completed/failed)', () => {
    expect(isDataChange({ phase: SYNC_PHASE.STARTED })).toBe(false);
    expect(isDataChange({ phase: SYNC_PHASE.COMPLETED })).toBe(false);
    expect(isDataChange(null)).toBe(false);
  });
});

describe('formatSyncLogLine', () => {
  it('formats each lifecycle phase', () => {
    expect(formatSyncLogLine({ phase: SYNC_PHASE.STARTED })).toEqual({ level: 'INFO', message: 'Sync started' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_STARTED, folderName: 'INBOX' }))
      .toEqual({ level: 'INFO', message: 'INBOX: starting…' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_PROGRESS, folderName: 'INBOX', batch: 3, added: 50, synced: 250 }))
      .toEqual({ level: 'INFO', message: 'INBOX: batch 3 +50 (250 total)' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_COMPLETE, folderName: 'INBOX', synced: 544 }))
      .toEqual({ level: 'INFO', message: 'INBOX: done, 544 messages' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.COMPLETED, folders: 4, messages: 600, elapsedSecs: 42 }))
      .toEqual({ level: 'INFO', message: 'Sync complete: 4 folders, 600 messages in 42s' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FAILED, error: 'boom' }))
      .toEqual({ level: 'ERROR', message: 'Sync failed: boom' });
  });

  it('formats incremental folder-complete by changes, and pluralizes', () => {
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_COMPLETE, folderName: 'INBOX', synced: 3, added: 3, deleted: 0 }))
      .toEqual({ level: 'INFO', message: 'INBOX: up to date (3 new)' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_COMPLETE, folderName: 'SENT', synced: 0, added: 0, deleted: 0 }))
      .toEqual({ level: 'INFO', message: 'SENT: up to date (no changes)' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_COMPLETE, folderName: 'INBOX', synced: 1 }))
      .toEqual({ level: 'INFO', message: 'INBOX: done, 1 message' });
    expect(formatSyncLogLine({ phase: SYNC_PHASE.COMPLETED, folders: 1, messages: 1, elapsedSecs: 2 }).message)
      .toBe('Sync complete: 1 folder, 1 message in 2s');
  });

  it('falls back to folderKey when no folderName, and to a generic error', () => {
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FOLDER_STARTED, folderKey: 'fld_x' }).message)
      .toBe('fld_x: starting…');
    expect(formatSyncLogLine({ phase: SYNC_PHASE.FAILED }).message).toBe('Sync failed: unknown error');
  });

  it('returns null for unknown phases', () => {
    expect(formatSyncLogLine({ phase: 'bogus' })).toBeNull();
    expect(formatSyncLogLine(null)).toBeNull();
  });
});
