import ComposePopup from './ComposePopup'
import DraftProvider from '../../hooks/DraftProvider'

const mockDraft = {
  id: 'msg_abc123',
  status: 'open',
  fromAddress: 'waseem@inbox2.dev',
  toAddress: '',
  ccAddress: '',
  subject: '',
  bodyHtml: '',
  bodyPlain: '',
  conversationId: null,
  saveStatus: 'saved',
  attachments: [],
}

export default {
  title: 'Components/ComposePopup',
  component: ComposePopup,
  decorators: [
    (Story) => (
      <DraftProvider orgId="test">
        <div>
          <Story />
        </div>
      </DraftProvider>
    ),
  ],
}

export const Default = {
  args: {
    draft: mockDraft,
    index: 0,
  },
}

export const WithContent = {
  args: {
    draft: {
      ...mockDraft,
      toAddress: 'user@example.com',
      subject: 'Re: Meeting tomorrow',
      bodyHtml: '<p>Thanks for your message. I will be there.</p>',
      bodyPlain: 'Thanks for your message. I will be there.',
    },
    index: 0,
  },
}
