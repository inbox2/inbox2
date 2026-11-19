import Icon from '../../components/Icon';
import { ToolbarButton } from '../../components/ToolbarGroup';
import DropdownMenu from '../../components/DropdownMenu/DropdownMenu';
import { bulkActionMenuItems, CONV_ACTION } from '../../lib/conversationActions';
import styles from '../../styles/layout.module.css';

// The conversation-list header: in selection mode it shows the selected count +
// a bulk Actions menu; otherwise the folder title + sort control (and Empty on
// Trash/Spam).
export default function ListHeader({
  selectedIds, clearSelection, hasUnreadInSelection, handleBulkAction, executePriority,
  activeView, selectedTags, canEmptyFolder, onEmptyFolder, folderRole, bulkRestorable,
  sortLabel, sortMenuItems, sortOrder,
}) {
  return (
    <div className={styles.listHeader}>
      {selectedIds.size > 0 ? (
        <>
          <h2 className={styles.listTitle}>
            <span className={styles.selectionDismiss} role="button" tabIndex={0} onClick={clearSelection}
              onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); clearSelection(); } }}><Icon name="xmark" size={10} /></span>
            <span className={styles.selectionCount}>{selectedIds.size}</span>
            selected
          </h2>
          <div className={styles.listControls}>
            <DropdownMenu
              trigger={<ToolbarButton icon="chevron.down">Actions</ToolbarButton>}
              items={bulkActionMenuItems(selectedIds, {
                hasUnread: hasUnreadInSelection,
                onArchive: () => handleBulkAction(CONV_ACTION.ARCHIVE),
                onSpam: () => handleBulkAction(CONV_ACTION.SPAM),
                onTrash: () => handleBulkAction(CONV_ACTION.TRASH),
                onMarkReadUnread: () => handleBulkAction(hasUnreadInSelection ? CONV_ACTION.MARK_READ : CONV_ACTION.MARK_UNREAD),
                executePriority,
                afterAction: clearSelection,
                folderRole,
                onMoveToInbox: bulkRestorable ? () => handleBulkAction(CONV_ACTION.MOVE_TO_INBOX) : undefined,
              })}
            />
          </div>
        </>
      ) : (
        <>
          <h2 className={styles.listTitle}>
            <Icon name={activeView?.icon || 'tray.fill'} size={13} className={styles.listTitleIcon} />
            {activeView?.name?.replace(/^label:/, '') || 'Inbox'}
            {selectedTags.size > 0 && ` · ${Array.from(selectedTags).join(', ')}`}
          </h2>
          <div className={styles.listControls}>
            {canEmptyFolder && (
              <ToolbarButton
                icon="trash"
                color="red"
                onClick={onEmptyFolder}
                title={`Permanently delete everything in ${activeView?.name || 'this folder'}`}
              >
                Empty
              </ToolbarButton>
            )}
            <DropdownMenu
              trigger={<ToolbarButton icon="chevron.down">{sortLabel}</ToolbarButton>}
              items={sortMenuItems}
              value={sortOrder}
            />
          </div>
        </>
      )}
    </div>
  );
}
