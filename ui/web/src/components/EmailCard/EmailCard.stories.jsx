import { DndContext } from '@dnd-kit/core'
import EmailCard, { EmailCardGhost } from './EmailCard'

const mockConv = {
  id: 'conv_1',
  subject: 'Q3 Planning Meeting',
  from_address: 'Alice Chen <alice@example.com>',
  snippet: 'Let me know your availability for next week. We need to finalize the roadmap before the board meeting.',
  updated_at: new Date(Date.now() - 1800000).toISOString(),
  read: true,
  has_attachment: false,
  urgent: false,
  important: false,
  providerType: 'inbox2',
}

export default {
  title: 'Components/EmailCard',
  component: EmailCard,
  decorators: [(Story) => <DndContext><Story /></DndContext>],
}

export const Default = {
  args: { conversation: mockConv },
}

export const Unread = {
  args: {
    conversation: { ...mockConv, id: 'conv_2', read: false },
  },
}

export const WithAttachment = {
  args: {
    conversation: { ...mockConv, id: 'conv_3', has_attachment: true },
  },
}

export const Urgent = {
  args: {
    conversation: { ...mockConv, id: 'conv_4', urgent: true },
  },
}

export const Important = {
  args: {
    conversation: { ...mockConv, id: 'conv_5', important: true },
  },
}

export const UrgentAndImportant = {
  args: {
    conversation: { ...mockConv, id: 'conv_6', urgent: true, important: true, read: false },
  },
}

export const ExternalProvider = {
  args: {
    conversation: { ...mockConv, id: 'conv_7', providerType: 'gmail' },
  },
}

export const DragGhost = {
  render: () => <EmailCardGhost conversation={mockConv} />,
}
