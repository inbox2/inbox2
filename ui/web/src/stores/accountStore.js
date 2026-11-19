import { create } from 'zustand';

const useAccountStore = create((set) => ({
  externalAccounts: [],
  setExternalAccounts: (val) => set((state) => ({
    externalAccounts: typeof val === 'function' ? val(state.externalAccounts) : val,
  })),
}));

export default useAccountStore;
