import '../../styles/management.css';
import DowngradeConfirmModal from './DowngradeConfirmModal';

/* The gated downgrade confirm with a realistic 422 `impact` payload. The
 * impact list must stay readable on the dark card (it shipped hardcoded #555
 * once) and the confirm button stays locked until the checkbox is ticked. */
export default {
  title: 'Console/DowngradeConfirmModal',
  component: DowngradeConfirmModal,
};

export const OverBothLimits = {
  args: {
    plan: { name: 'Free' },
    impact: { domains_over: 2, collaborators_over: 3 },
    busy: false,
    onCancel: () => {},
    onConfirm: () => {},
  },
};

export const OverCollaboratorsOnly = {
  args: {
    ...OverBothLimits.args,
    impact: { domains_over: 0, collaborators_over: 1 },
  },
};

export const Busy = {
  args: {
    ...OverBothLimits.args,
    busy: true,
  },
};
