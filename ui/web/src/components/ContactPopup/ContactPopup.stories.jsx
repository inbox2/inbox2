import ContactPopup from './ContactPopup'

const noop = () => {}

export default {
  title: 'Components/ContactPopup',
  component: ContactPopup,
}

export const Default = {
  args: {
    name: 'Dana Lee',
    email: 'dana@partner.com',
    onSendEmail: noop,
    onCopyEmail: noop,
    onViewSender: noop,
  },
}

export const NoName = {
  args: {
    name: '',
    email: 'billing@acme.com',
    onSendEmail: noop,
    onCopyEmail: noop,
    onViewSender: noop,
  },
}

export const SendOnly = {
  args: {
    name: 'Marcus Vega',
    email: 'marcus@inbox2.dev',
    onSendEmail: noop,
  },
}
