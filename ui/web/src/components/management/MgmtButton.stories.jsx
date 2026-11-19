import '../../styles/management.css';
import MgmtButton from './MgmtButton';

/* The ONE console button (per the component contract in MgmtButton.jsx) —
 * every variant/size rendered under the `management` token scope, the same
 * scope the console gives it. */
export default {
  title: 'Management/MgmtButton',
  component: MgmtButton,
};

export const Variants = {
  render: () => (
    <div className="management">
      <MgmtButton variant="primary">Primary</MgmtButton>{' '}
      <MgmtButton variant="glass">Glass</MgmtButton>{' '}
      <MgmtButton variant="dark">Dark</MgmtButton>{' '}
      <MgmtButton variant="ghost">Ghost</MgmtButton>{' '}
      <MgmtButton variant="danger">Danger</MgmtButton>
    </div>
  ),
};

export const Small = {
  render: () => (
    <div className="management">
      <MgmtButton size="sm">Save</MgmtButton>{' '}
      <MgmtButton size="sm" variant="danger">Remove</MgmtButton>
    </div>
  ),
};

export const Block = {
  render: () => (
    <div className="management">
      <MgmtButton block>Send invite</MgmtButton>
    </div>
  ),
};

export const Disabled = {
  render: () => (
    <div className="management">
      <MgmtButton disabled>Inviting…</MgmtButton>
    </div>
  ),
};
