import SignedOutScreen from './SignedOutScreen'

export default {
  title: 'Components/SignedOutScreen',
  component: SignedOutScreen,
  args: { onSignIn: () => {} },
}

export const SignedOutElsewhere = {}

export const SessionEnded = { args: { reason: 'expired' } }

export const WithUnsavedWork = {
  args: { unsaved: [{ label: 'Page: Launch plan', text: '# Launch plan\n\nShip Disk.' }, { label: 'Message to ana@acme.test', text: 'Hi Ana,' }] },
}

export const ManagementSkin = { args: { skin: 'management', reason: 'revoked' } }
