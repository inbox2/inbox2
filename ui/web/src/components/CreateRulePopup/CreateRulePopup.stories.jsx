import CreateRulePopup from './CreateRulePopup'

const noop = () => {}

export default {
  title: 'Components/CreateRulePopup',
  component: CreateRulePopup,
}

export const Default = {
  args: {
    open: true,
    onClose: noop,
    onSaved: noop,
    prefill: {},
  },
}

export const PrefilledFromMessage = {
  args: {
    open: true,
    onClose: noop,
    onSaved: noop,
    prefill: {
      from: 'billing@acme.com',
      to: 'team@inbox2.dev',
      subject: 'Invoice #4821',
      hasAttachment: true,
    },
  },
}
