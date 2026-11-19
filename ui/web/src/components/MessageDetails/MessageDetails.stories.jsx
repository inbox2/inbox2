import MessageDetails from './MessageDetails'

const mockMessage = {
  to_address: 'team@inbox2.dev',
  cc_address: 'bob@example.com, carol@example.com',
  bcc_address: '',
  subject: 'Q3 Planning Meeting',
  created_at: new Date().toISOString(),
  message_id_header: '<abc123@mail.example.com>',
  in_reply_to: '<prev456@mail.example.com>',
  references_header: '<prev456@mail.example.com> <orig789@mail.example.com>',
  content_type: 'multipart/alternative',
}

export default {
  title: 'Components/MessageDetails',
  component: MessageDetails,
}

export const Collapsed = {
  args: {
    message: mockMessage,
    expanded: false,
  },
}

export const Expanded = {
  args: {
    message: mockMessage,
    expanded: true,
  },
}

export const WithAttachments = {
  args: {
    message: mockMessage,
    expanded: false,
    attachments: [
      { name: 'Q3-roadmap.pdf', size: 245000 },
      { name: 'budget.xlsx', size: 89000 },
      { name: 'screenshot.png', size: 1200000 },
    ],
    onAttachmentClick: () => {},
  },
}

export const MinimalHeaders = {
  args: {
    message: {
      to_address: 'user@example.com',
      subject: 'Hello',
      created_at: new Date().toISOString(),
    },
    expanded: true,
  },
}
