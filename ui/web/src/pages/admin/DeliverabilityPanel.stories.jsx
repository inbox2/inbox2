import '../../styles/management.css';
import api from '../../lib/api';
import DeliverabilityPanel from './DeliverabilityPanel';

/* The domain-settings Deliverability tab with a mocked provider catalog —
 * deterministic render of both modes (the panel fetches on mount, so the api
 * singleton's read is stubbed per story). */

const PROVIDERS = [
  {
    kind: 'ses', name: 'Amazon SES',
    fields: [
      { key: 'region', label: 'Region', type: 'select', options: ['eu-west-1', 'us-east-1'], default: 'eu-west-1' },
      { key: 'access_key_id', label: 'Access key ID', type: 'text' },
      { key: 'secret_access_key', label: 'Secret access key', type: 'secret' },
    ],
  },
  {
    kind: 'sendgrid', name: 'SendGrid',
    fields: [{ key: 'api_key', label: 'API key', type: 'secret' }],
  },
];

function stubDeliverability(payload) {
  return (Story) => {
    api.getDeliverability = async () => ({ deliverability: { providers: PROVIDERS, ...payload } });
    return <Story />;
  };
}

export default {
  title: 'Console/DeliverabilityPanel',
  component: DeliverabilityPanel,
  args: {
    domain: { key: 'org_1', domain: 'acme.com' },
  },
};

export const Builtin = {
  decorators: [stubDeliverability({ mode: 'builtin', config: {} })],
};

export const CustomSesSaved = {
  decorators: [
    stubDeliverability({
      mode: 'custom',
      kind: 'ses',
      config: { region: 'eu-west-1', access_key_id: 'AKIA…', secret_access_key_set: true },
    }),
  ],
};
