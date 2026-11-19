import { useEffect } from 'react';
import useAccountStatusStore from '../stores/accountStatusStore';

// Seeds the shared accountStatusStore from the loaded account list. The live
// `account-status` subscription lives in the store module itself — it must stay
// active on every route, not only where this hook is mounted.
export default function useAccountStatuses(accounts) {
  const seed = useAccountStatusStore(s => s.seed);

  useEffect(() => { seed(accounts); }, [accounts, seed]);
}
