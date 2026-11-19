import { useCallback } from 'react';
import useTransientFlag from './useTransientFlag';

// Copy text to the clipboard and flash a "copied" flag for `duration` ms.
// Returns [copied, copy]. Replaces the copy + setCopied(true) + reset-timer
// blocks duplicated across ApiKeysPage, SyncConsole, OAuthDevUrl, etc.
export default function useCopyToClipboard(duration = 2000) {
  const [copied, flash] = useTransientFlag(duration);

  const copy = useCallback(async (text) => {
    try {
      await navigator.clipboard.writeText(text);
      flash();
      return true;
    } catch {
      return false;
    }
  }, [flash]);

  return [copied, copy];
}
