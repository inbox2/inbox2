import '../../styles/management.css';
import InviteMxModal from './InviteMxModal';

/* The console "Invite a teammate" popup, rendered with realistic domain data.
 * Guards the regressions this modal actually shipped with: an unreadable
 * title outside the console's .page token scope, and a confirmation view
 * reading a field the serializer never returned. */
const DOMAINS = [
  { key: 'org_1', domain: 'acme.com', displayName: 'Acme', logoUrl: null },
  { key: 'org_2', domain: 'acme.dev', displayName: 'Acme Dev', logoUrl: null },
];

export default {
  title: 'Console/InviteMxModal',
  component: InviteMxModal,
};

export const MultiDomain = {
  args: {
    domains: DOMAINS,
    onClose: () => {},
  },
};

export const LockedDomain = {
  args: {
    domains: [DOMAINS[0]],
    lockedDomain: true,
    onClose: () => {},
  },
};
