import '../../styles/management.css';
import ChangePasswordModal from './ChangePasswordModal';

/* The console change-password popup (current password + new + confirm).
 * Render-only: submission hits the api singleton, which stories leave alone. */
export default {
  title: 'Console/ChangePasswordModal',
  component: ChangePasswordModal,
};

export const Default = {
  args: {
    onClose: () => {},
  },
};
