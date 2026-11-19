import '../../styles/management.css';
import MgmtModal from './MgmtModal';
import MgmtButton from './MgmtButton';

/* MgmtModal carries its own `management` token scope on the overlay — these
 * stories render it exactly as the console does, INCLUDING when opened from a
 * page that is not under the console's .page wrapper (the black-on-dark title
 * regression lived there: styles referencing .page-local aliases went
 * invisible outside it). */
export default {
  title: 'Management/MgmtModal',
  component: MgmtModal,
};

export const Basic = {
  render: () => (
    <MgmtModal open onClose={() => {}} width={480}>
      <h2>Modal title</h2>
      <p>Body copy inside the management scope. The title above must be readable
        on the dark card in both themes.</p>
      <MgmtButton onClick={() => {}}>Primary action</MgmtButton>
    </MgmtModal>
  ),
};

export const WithForm = {
  render: () => (
    <MgmtModal open onClose={() => {}} onSubmit={() => {}} width={520}>
      <h2>Enter-to-submit form</h2>
      <p>The first input autofocuses; Enter submits; Escape closes.</p>
      <input placeholder="autofocused field" />
    </MgmtModal>
  ),
};
