import '../../styles/management.css';
import MgmtConfirm from './MgmtConfirm';

export default {
  title: 'Management/MgmtConfirm',
  component: MgmtConfirm,
};

export const Basic = {
  args: {
    open: true,
    title: 'Remove this member?',
    message: 'They lose access to the domain immediately. Their mail stays in the pool.',
    confirmLabel: 'Remove',
    onConfirm: () => {},
    onClose: () => {},
  },
};

export const Danger = {
  args: {
    ...Basic.args,
    title: 'Delete this domain?',
    message: 'All mail routing for acme.com stops. This cannot be undone.',
    confirmLabel: 'Delete domain',
    danger: true,
  },
};

export const TypeToConfirm = {
  args: {
    ...Danger.args,
    confirmText: 'acme.com',
  },
};

export const Busy = {
  args: {
    ...Basic.args,
    busy: true,
  },
};
