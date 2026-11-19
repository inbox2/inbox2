import { useCallback, useState } from 'react';
import SendToDialog from './SendToDialog';
import useUndoStore from '../../stores/undoStore';
import { addLoreSent, LORE_SENT_CHANGED } from '../../lib/mcpClient';
import log from '../../lib/log';

/**
 * The Send to… dialog for any Lore surface: `open(item)` shows it; `dialog` is
 * the element to render. A successful Create toasts the app's answer (the new
 * issue's id or URL) and stores it, so the item shows a chip with the link. The
 * item stays open until someone ticks it (decided 2026-11-09).
 */
export default function useSendTo() {
  const [item, setItem] = useState(null);
  const open = useCallback((i) => setItem(i), []);
  const onSent = useCallback(({ item: sentItem, connection, summary }) => {
    addLoreSent(sentItem.uid, connection?.name || '', summary)
      .then(() => document.dispatchEvent(new CustomEvent(LORE_SENT_CHANGED)))
      .catch((e) => log.warn('Lore', `could not store the sent reference: ${e?.message || e}`));
    useUndoStore.getState().notify({
      description: `Sent to ${connection?.name || 'the app'}${summary ? `: ${summary}` : ''}`,
      icon: 'paperplane',
    });
    setItem(null);
  }, []);
  const dialog = item ? <SendToDialog item={item} onClose={() => setItem(null)} onSent={onSent} /> : null;
  return { open, dialog };
}
