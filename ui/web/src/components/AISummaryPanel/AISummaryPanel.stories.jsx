import AISummaryPanel from './AISummaryPanel'

export default {
  title: 'Components/AISummaryPanel',
  component: AISummaryPanel,
}

export const Default = {
  args: {
    conversationId: 'conv_123',
    threadText: 'From: alice@example.com\nHi team, can we schedule a planning meeting for Thursday?\n---\nFrom: bob@example.com\nThursday works for me. How about 2pm?\n---\nFrom: alice@example.com\nPerfect, I will send a calendar invite.',
    messages: [
      { id: 'msg_1', from_address: 'alice@example.com', body_plain: 'Hi team, can we schedule a planning meeting for Thursday?' },
      { id: 'msg_2', from_address: 'bob@example.com', body_plain: 'Thursday works for me. How about 2pm?' },
      { id: 'msg_3', from_address: 'alice@example.com', body_plain: 'Perfect, I will send a calendar invite.' },
    ],
    onTitleChange: () => {},
  },
}

export const SingleMessage = {
  args: {
    conversationId: 'conv_456',
    threadText: 'Hi, please find attached the Q3 report.',
    messages: [
      { id: 'msg_1', from_address: 'alice@example.com', body_plain: 'Hi, please find attached the Q3 report.' },
    ],
    onTitleChange: () => {},
  },
}
