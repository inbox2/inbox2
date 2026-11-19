import MessageShortcuts from './MessageShortcuts'
import DraftProvider from '../../hooks/DraftProvider'

// MessageShortcuts renders nothing — it is a keyboard-binding bridge. It must be
// mounted inside a DraftProvider because its draft actions (reply/forward) use
// useDrafts(), which throws outside that context.
const conversation = {
  id: 'conv_8Kd2mQ',
  key: 'conv_8Kd2mQ',
  subject: 'Re: Project kickoff',
  from_address: 'colleague@inbox2.dev',
  to_address: 'waseem@inbox2.dev',
  snippet: 'Looks good — let us sync tomorrow.',
}

export default {
  title: 'Components/MessageShortcuts',
  component: MessageShortcuts,
  parameters: {
    docs: {
      description: {
        component:
          'Non-visual component that binds the message-action keyboard shortcuts (reply, reply-all, forward, status/triage actions) for the selected conversation. It renders nothing; it exists so the draft actions can call useDrafts(), which requires a DraftProvider boundary. Each view passes the callbacks it supports — omitted callbacks make their shortcuts no-ops. It also listens for `compose-forward` / `compose-reply-all` DOM events fired by list context menus.',
      },
    },
  },
  decorators: [
    (Story) => (
      <DraftProvider orgId="org_demo">
        <Story />
      </DraftProvider>
    ),
  ],
}

export const Default = {
  render: () => (
    <div>
      <p>
        MessageShortcuts renders no UI. It binds keyboard shortcuts (reply,
        reply-all, forward, triage) for the selected conversation and bridges the
        list context-menu compose events into the DraftProvider context.
      </p>
      <MessageShortcuts
        conversation={conversation}
        defaultFrom="waseem@inbox2.dev"
        enabled
        onStatusAction={() => {}}
        onTriage={() => {}}
      />
    </div>
  ),
}

export const Disabled = {
  render: () => (
    <div>
      <p>
        With <code>enabled=false</code> the shortcuts are not bound — useful for
        views where another handler owns the keyboard.
      </p>
      <MessageShortcuts conversation={conversation} defaultFrom="waseem@inbox2.dev" enabled={false} />
    </div>
  ),
}
