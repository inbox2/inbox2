import Icon from '../Icon';
import { FOLDER_KIND, VIEW_KIND_FOLDER } from '../../lib/addressFolders';
import styles from './AddressFolderTree.module.css';

// Top of a shared folder's list when you can read the address but not send as
// it. Reply-as is an admin setting; there is no request flow (decided 2026-11).
export default function ReadOnlyFolderNotice({ view }) {
  if (view?.kind !== VIEW_KIND_FOLDER || view.folderKind !== FOLDER_KIND.SHARED || view.canReply) return null;
  return (
    <div className={styles.notice} role="status">
      <Icon name="eye" size={13} className={styles.noticeIcon} />
      <span>You can read {view.name} but not reply as it. An admin gives reply-as in the console.</span>
    </div>
  );
}
