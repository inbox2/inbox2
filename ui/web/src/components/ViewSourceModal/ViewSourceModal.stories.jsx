import ViewSourceModal from './ViewSourceModal'

export default {
  title: 'Components/ViewSourceModal',
  component: ViewSourceModal,
}

export const WithSource = {
  args: {
    open: true,
    loading: false,
    onClose: () => {},
    source: {
      message_id: '<abc123@mail.example.com>',
      from: 'Alice Chen <alice@example.com>',
      to: 'team@inbox2.dev',
      subject: 'Q3 Planning Meeting',
      date: 'Mon, 26 May 2025 10:30:00 -0700',
      content_type: 'multipart/alternative',
      headers: {
        'DKIM-Signature': 'v=1; a=rsa-sha256; d=example.com',
        'X-Mailer': 'Thunderbird 115.0',
      },
    },
  },
}

export const Loading = {
  args: {
    open: true,
    loading: true,
    source: null,
    onClose: () => {},
  },
}

export const ErrorState = {
  args: {
    open: true,
    loading: false,
    source: { error: 'Failed to load message source' },
    onClose: () => {},
  },
}
