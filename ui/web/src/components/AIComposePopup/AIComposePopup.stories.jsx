import AIComposePopup from './AIComposePopup'

const mockMessages = [
  {
    from_address: 'Dana Lee <dana@partner.com>',
    body_plain:
      'Hi — are you free to meet next Tuesday to walk through the Q3 numbers? ' +
      'Happy to come to your office or do a call, whichever is easier.',
  },
  {
    from_address: 'waseem@inbox2.dev',
    body_plain: 'Tuesday is tight for me — let me check and get back to you.',
  },
]

const noop = () => {}

export default {
  title: 'Components/AIComposePopup',
  component: AIComposePopup,
}

export const Default = {
  args: {
    open: true,
    onClose: noop,
    onInsert: noop,
    messages: mockMessages,
    senderName: 'Dana Lee',
    seed: '',
  },
}

export const WithSeedInstruction = {
  args: {
    open: true,
    onClose: noop,
    onInsert: noop,
    messages: mockMessages,
    senderName: 'Dana Lee',
    seed: 'politely decline Tuesday and suggest the following Thursday instead',
  },
}

export const NoThreadContext = {
  args: {
    open: true,
    onClose: noop,
    onInsert: noop,
    messages: [],
    senderName: '',
    seed: '',
  },
}
