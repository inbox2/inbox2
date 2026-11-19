import RoutingPanel from './RoutingPanel'

// A routed conversation. Rules + runs are loaded from local SQLite over Tauri,
// so in Storybook (no Tauri) the rules list stays empty and only the
// "Create rule…" affordance shows — which is the correct web-build behaviour.
const conversation = {
  id: 'conv_8Kd2mQ',
  key: 'conv_8Kd2mQ',
  subject: 'Invoice #4821 — payment due',
  from_address: 'billing@acme.example.com',
  to_address: 'waseem@inbox2.dev',
  snippet: 'Your invoice is attached. Please remit payment within 30 days.',
  has_attachment: true,
}

export default {
  title: 'Components/RoutingPanel',
  component: RoutingPanel,
  parameters: {
    docs: {
      description: {
        component:
          'Context-panel routing group for the open conversation: which local rules match it, each with its latest run status, plus a "Create rule…" affordance prefilled from the conversation. Rules + runs are desktop-only (local SQLite via Tauri); in the browser/Storybook the list is empty and only the create button shows.',
      },
    },
  },
}

export const Default = {
  render: () => <RoutingPanel conversation={conversation} />,
}

export const NoConversation = {
  render: () => (
    <div>
      <p>With no conversation selected, RoutingPanel renders nothing.</p>
      <RoutingPanel conversation={null} />
    </div>
  ),
}
