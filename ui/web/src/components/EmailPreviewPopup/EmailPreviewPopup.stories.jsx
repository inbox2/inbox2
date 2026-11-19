import EmailPreviewPopup from './EmailPreviewPopup'

const mockConv = {
  id: 'conv_1',
  subject: 'Q3 Planning Meeting',
  from_address: 'Alice Chen <alice@example.com>',
  to_address: 'team@inbox2.dev',
  cc_address: 'bob@example.com',
  snippet: 'Hi team,\n\nLet me know your availability for next week. We need to finalize the Q3 roadmap before the board meeting on Friday.\n\nKey items to discuss:\n- Revenue targets\n- Hiring plan\n- Product milestones\n\nBest,\nAlice',
  body_plain: '',
  updated_at: new Date().toISOString(),
  read: false,
  urgent: false,
  important: false,
  has_attachment: false,
  attachments: [],
}

const anchorRect = { top: 120, left: 200, bottom: 160, right: 500, width: 300, height: 40 }

const noop = () => {}

export default {
  title: 'Components/EmailPreviewPopup',
  component: EmailPreviewPopup,
}

export const Default = {
  args: {
    conversation: mockConv,
    anchorRect,
    onClose: noop,
    onView: noop,
    onArchive: noop,
    onTrash: noop,
    onMarkRead: noop,
    onUrgent: noop,
    onImportant: noop,
  },
}

export const WithAttachments = {
  args: {
    conversation: {
      ...mockConv,
      has_attachment: true,
      attachments: [
        { filename: 'Q3-roadmap.pdf' },
        { filename: 'budget.xlsx' },
      ],
    },
    anchorRect,
    onClose: noop,
    onView: noop,
    onArchive: noop,
    onTrash: noop,
    onMarkRead: noop,
    onUrgent: noop,
    onImportant: noop,
  },
}

export const ReadMessage = {
  args: {
    conversation: { ...mockConv, read: true },
    anchorRect,
    onClose: noop,
    onView: noop,
    onArchive: noop,
    onTrash: noop,
    onMarkRead: noop,
    onUrgent: noop,
    onImportant: noop,
  },
}

export const UrgentAndImportant = {
  args: {
    conversation: { ...mockConv, urgent: true, important: true },
    anchorRect,
    onClose: noop,
    onView: noop,
    onArchive: noop,
    onTrash: noop,
    onMarkRead: noop,
    onUrgent: noop,
    onImportant: noop,
  },
}
