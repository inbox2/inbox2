import { create } from 'zustand';

const ACTIVE_ACCOUNT_KEY = 'inbox2_active_account';

/**
 * Transient Explorer state that survives tab switches.
 * Search and account selection live in memory; account key syncs to localStorage.
 */
const useExplorerStore = create((set) => ({
  // Search / filter
  searchInput: '',

  // Active account selection (initialized from localStorage)
  unifiedMode: !localStorage.getItem(ACTIVE_ACCOUNT_KEY),
  activeAccountKey: localStorage.getItem(ACTIVE_ACCOUNT_KEY) || null,

  // Which graph the Explorer draws: 'entities' (Lore ontology, default) or 'mailboxes'
  graphMode: 'entities',

  // Setters
  setGraphMode: (graphMode) => set({ graphMode }),
  setSearchInput: (searchInput) => set({ searchInput }),
  setUnifiedMode: (unifiedMode) => set({ unifiedMode }),
  setActiveAccountKey: (activeAccountKey) => set({ activeAccountKey }),
}));

export default useExplorerStore;
