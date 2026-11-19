import FormField, { ErrorMessage } from './FormField'

export default {
  title: 'Components/FormField',
  component: FormField,
}

export const Default = {
  render: () => <FormField label="Email address" placeholder="you@example.com" />,
}

export const WithHint = {
  render: () => (
    <FormField
      label="Password"
      type="password"
      placeholder="App password"
      hint="Encrypted on this device only"
    />
  ),
}

export const Error = {
  render: () => <ErrorMessage>Connection failed: invalid credentials</ErrorMessage>,
}
