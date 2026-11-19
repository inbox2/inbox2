import ConfirmDialog from './ConfirmDialog'

export default {
  title: 'Components/ConfirmDialog',
  component: ConfirmDialog,
}

export const Danger = {
  args: {
    open: true,
    title: 'Discard draft?',
    message: 'This draft will be permanently deleted and cannot be recovered.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep editing',
    variant: 'danger',
    onConfirm: () => {},
    onCancel: () => {},
  },
}

export const Default = {
  args: {
    open: true,
    title: 'Send message?',
    message: 'Your message will be sent to 3 recipients.',
    confirmLabel: 'Send',
    cancelLabel: 'Cancel',
    variant: 'default',
    onConfirm: () => {},
    onCancel: () => {},
  },
}
