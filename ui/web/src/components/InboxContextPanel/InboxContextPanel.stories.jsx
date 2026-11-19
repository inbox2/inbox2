import InboxContextPanel from './InboxContextPanel'
import { APOLLO_CACHE } from '../../lib/storageKeys'

const mockConversation = {
  id: 'conv_1',
  subject: 'Q3 Planning Meeting',
  from_address: 'Alice Chen <alice@example.com>',
  to_address: 'team@inbox2.dev',
  status: 'open',
  assignee: null,
  tags: ['planning', 'q3'],
  messages: [
    {
      id: 'msg_1',
      from_address: 'Alice Chen <alice@example.com>',
      body_plain: 'Hi team, let me know your availability for next week.',
      created_at: new Date(Date.now() - 86400000).toISOString(),
    },
  ],
  snippet: 'Let me know your availability for next week.',
  updated_at: new Date().toISOString(),
}

export default {
  title: 'Components/InboxContextPanel',
  component: InboxContextPanel,
}

export const Default = {
  args: {
    conversation: mockConversation,
  },
}

// Enrichment now renders from the local Apollo cache (no auto-fetch). Seed the
// cache so the story shows a contact that's already been loaded from Apollo.
export const WithEnrichment = {
  args: {
    conversation: mockConversation,
  },
  decorators: [
    (Story) => {
      localStorage.setItem(APOLLO_CACHE, JSON.stringify({
        'alice@example.com': {
          ts: Date.now(),
          data: {
            name: 'Alice Chen',
            photo_url: null,
            title: 'VP of Engineering',
            company: 'Acme Corp',
            linkedin_url: 'https://linkedin.com/in/alicechen',
            city: 'San Francisco',
            state: 'CA',
            country: 'US',
          },
        },
      }))
      return <Story />
    },
  ],
}

export const NoConversation = {
  args: {
    conversation: null,
  },
}
