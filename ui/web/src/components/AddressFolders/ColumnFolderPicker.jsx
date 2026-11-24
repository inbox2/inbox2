import { useState } from 'react';
import Icon from '../Icon';
import ContextMenu from '../DropdownMenu/ContextMenu';
import useAddressFolders from '../../hooks/useAddressFolders';
import { folderKeyLabel, folderLabel } from '../../lib/addressFolders';
import styles from './AddressFolderTree.module.css';

/**
 * Folder picker in an MX domain column's header (unified inbox, list mode).
 * Picks the folder the column lists; a folder's … opens it as its own column.
 */
export default function ColumnFolderPicker({ orgId, domainKey, value, onChange, onAddColumn }) {
  const [menuAt, setMenuAt] = useState(null);
  // Loaded up front (not on open) so the menu has its items when it takes focus.
  const { folders } = useAddressFolders(orgId, domainKey);
  const count = (f) => (f.unread > 0 ? ` · ${f.unread}` : '');
  // One row per folder: click lists it here; its … opens it as its own column.
  const current = value || 'inbox';
  const items = folders.length === 0
    ? [{ heading: 'Loading folders…' }]
    : folders.map((f) => ({
      label: `${folderLabel(f)}${count(f)}`,
      icon: f.key === current ? 'checkmark' : <span />,
      onSelect: () => onChange(f.key),
      ...(f.key === current ? {} : { more: [{ label: 'Open as column', icon: 'plus', onSelect: () => onAddColumn(f.key) }] }),
    }));
  return (
    <>
      <button
        type="button"
        className={styles.picker}
        aria-haspopup="menu"
        aria-label={`Folder: ${folderKeyLabel(value)}`}
        onClick={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          setMenuAt({ x: r.left, y: r.bottom + 2 });
        }}
      >
        <span className={styles.pickerLabel}>{folderKeyLabel(value)}</span>
        <Icon name="chevron.down" size={9} />
      </button>
      <ContextMenu open={!!menuAt} position={menuAt} items={items} onClose={() => setMenuAt(null)} />
    </>
  );
}
