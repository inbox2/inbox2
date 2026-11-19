import AddAccountModal from './AddAccountModal'
import AuthProvider from '../../hooks/AuthProvider'

const noop = () => {}

export default {
  title: 'Components/AddAccountModal',
  component: AddAccountModal,
  // AddAccountModal reads auth context for the inline "Sign in to your MX" flow.
  decorators: [(Story) => <AuthProvider><Story /></AuthProvider>],
}

export const Default = {
  args: {
    open: true,
    onClose: noop,
    onSubmit: async () => {},
    onGmailConnected: noop,
    onMicrosoftConnected: noop,
    onConnectMx: noop,
  },
}

export const Closed = {
  args: {
    open: false,
    onClose: noop,
    onSubmit: async () => {},
    onGmailConnected: noop,
    onMicrosoftConnected: noop,
    onConnectMx: noop,
  },
}
