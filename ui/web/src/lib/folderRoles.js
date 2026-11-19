// Well-known folder roles — the single source for these string values on the
// frontend (mirrors the sync engine's `well_known_role` column). Never inline
// 'inbox' / 'sent' / 'drafts' as raw literals; reference these instead.
export const FOLDER_ROLE = {
  INBOX: 'inbox',
  SENT: 'sent',
  DRAFTS: 'drafts',
};
