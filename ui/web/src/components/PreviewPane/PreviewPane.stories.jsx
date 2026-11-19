import PreviewPane from './PreviewPane'

export default {
  title: 'Components/PreviewPane',
  component: PreviewPane,
}

export const Default = {
  args: {
    html: '<h2>Hello!</h2><p>This is a <strong>preview</strong> of your email as your recipient will see it.</p><ul><li>First point</li><li>Second point</li></ul><p>Best regards,<br/>The Inbox2 Team</p>',
  },
}

export const Empty = {
  args: {
    html: '',
  },
}
