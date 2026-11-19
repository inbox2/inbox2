import SmartReplyBar from './SmartReplyBar'

export default {
  title: 'Components/SmartReplyBar',
  component: SmartReplyBar,
}

export const Default = {
  args: {
    emailText: 'Hi, can we schedule a meeting for Thursday at 2pm to discuss the Q3 roadmap?',
    senderName: 'Alice',
    onSelectReply: () => {},
  },
}
