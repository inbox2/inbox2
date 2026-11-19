import { MemoryRouter } from 'react-router'
import ConversationDetail from './ConversationDetail'
import DraftProvider from '../../hooks/DraftProvider'

const mockConversation = {
  id: 'conv_1',
  subject: 'Q3 Planning Meeting',
  from_address: 'Alice Chen <alice@example.com>',
  to_address: 'team@inbox2.dev',
  status: 'open',
  read: true,
  urgent: false,
  important: false,
  notes: [],
  messages: [
    {
      id: 'msg_1',
      from_address: 'Alice Chen <alice@example.com>',
      to_address: 'team@inbox2.dev',
      cc_address: '',
      subject: 'Q3 Planning Meeting',
      body_html: '<p>Hi team,</p><p>Let me know your availability for next week. We need to finalize the Q3 roadmap.</p><p>Best,<br>Alice</p>',
      body_plain: 'Hi team,\n\nLet me know your availability for next week. We need to finalize the Q3 roadmap.\n\nBest,\nAlice',
      is_inbound: true,
      is_draft: false,
      created_at: new Date(Date.now() - 86400000).toISOString(),
    },
    {
      id: 'msg_2',
      from_address: 'Bob Smith <bob@inbox2.dev>',
      to_address: 'Alice Chen <alice@example.com>',
      cc_address: 'team@inbox2.dev',
      subject: 'Re: Q3 Planning Meeting',
      body_html: '<p>Thursday at 2pm works for me.</p><blockquote><p>Hi team, Let me know your availability...</p></blockquote>',
      body_plain: 'Thursday at 2pm works for me.\n\n> Hi team, Let me know your availability...',
      is_inbound: false,
      is_draft: false,
      created_at: new Date(Date.now() - 43200000).toISOString(),
    },
  ],
}

const noop = () => {}

export default {
  title: 'Components/ConversationDetail',
  component: ConversationDetail,
  decorators: [
    (Story) => (
      <MemoryRouter>
        <DraftProvider orgId="test">
          <Story />
        </DraftProvider>
      </MemoryRouter>
    ),
  ],
}

export const Default = {
  args: {
    conversation: mockConversation,
    defaultFrom: 'waseem@inbox2.dev',
    orgId: 'org_demo',
    onArchive: noop,
    onTrash: noop,
    onConversationAction: noop,
    executePriority: noop,
    wasUnread: false,
    focusedMsgIndex: -1,
    enrichingKeys: new Set(),
  },
}

export const Unread = {
  args: {
    conversation: { ...mockConversation, read: false },
    defaultFrom: 'waseem@inbox2.dev',
    orgId: 'org_demo',
    onArchive: noop,
    onTrash: noop,
    onConversationAction: noop,
    executePriority: noop,
    wasUnread: true,
    focusedMsgIndex: -1,
    enrichingKeys: new Set(),
  },
}

export const SingleMessage = {
  args: {
    conversation: {
      ...mockConversation,
      messages: [mockConversation.messages[0]],
    },
    defaultFrom: 'waseem@inbox2.dev',
    orgId: 'org_demo',
    onArchive: noop,
    onTrash: noop,
    onConversationAction: noop,
    executePriority: noop,
    wasUnread: false,
    focusedMsgIndex: 0,
    enrichingKeys: new Set(),
  },
}
