import { ComposePopups, ComposeShortcuts } from '../ComposeWidgets/ComposeWidgets';
import AIOnboardingModal from '../AIOnboardingModal';
import DraftBar from '../DraftBar';
import NotificationPanel from '../NotificationPanel/NotificationPanel';
import ContextMenu from '../DropdownMenu/ContextMenu';
import ConnectionIndicator from '../ConnectionIndicator/ConnectionIndicator';
import AddAccountModal from '../AddAccountModal/AddAccountModal';
import SyncConsole from '../SyncConsole/SyncConsole';
import MessageShortcuts from '../MessageShortcuts';
import ShortcutsHelp from '../ShortcutsHelp';
import UndoToast from '../UndoToast/UndoToast';
import { isTauri } from '../../lib/tauri';

// The inbox's screen-level overlays: notifications, the add-account / sync-console
// modals, compose popups, keyboard-shortcut listeners, the undo toast, and the
// right-click context menu. (The command palette is mounted once for the whole
// app in routes.jsx; this page registers its actions via usePaletteActions.) Pulled out of
// InboxPage so the page render reads as layout, not a wall of trailing portals.
// Props are grouped per overlay to keep the interface legible.
export default function InboxOverlays({
  notifications,
  addAccount,
  syncConsole,
  defaultFrom,
  composeFrom = defaultFrom,
  messageShortcuts,
  help,
  undo,
  contextMenu,
}) {
  return (
    <>
      <NotificationPanel open={notifications.open} onClose={notifications.onClose} />
      <ConnectionIndicator />
      <AddAccountModal
        open={addAccount.open}
        onClose={addAccount.onClose}
        onSubmit={addAccount.onSubmit}
        onMetaSubmit={addAccount.onMetaSubmit}
        onGmailConnected={addAccount.onGmailConnected}
        onMicrosoftConnected={addAccount.onMicrosoftConnected}
        onConnectMx={addAccount.onConnectMx}
      />
      <SyncConsole
        open={syncConsole.open}
        onClose={syncConsole.onClose}
        account={syncConsole.account}
        folders={syncConsole.folders}
        syncStatus={{ capabilities: [] }}
        logs={syncConsole.logs}
        diagnostics={syncConsole.diagnostics}
        syncing={syncConsole.syncing}
      />
      <ComposePopups />
      <DraftBar />
      <ComposeShortcuts defaultFrom={composeFrom} />
      <MessageShortcuts
        conversation={messageShortcuts.conversation}
        orgId={messageShortcuts.orgId}
        defaultFrom={defaultFrom}
        onStatusAction={messageShortcuts.onStatusAction}
        onTriage={messageShortcuts.onTriage}
      />
      <ShortcutsHelp open={help.open} onClose={help.onClose} />
      <UndoToast entries={undo.entries} onUndo={undo.onUndo} onDismiss={undo.onDismiss} />
      {isTauri() && <AIOnboardingModal />}
      <ContextMenu
        open={contextMenu.open}
        position={contextMenu.position}
        items={contextMenu.items}
        onClose={contextMenu.onClose}
      />
    </>
  );
}
