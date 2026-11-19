import Checkbox from './Checkbox'

export default {
  title: 'Components/Checkbox',
  component: Checkbox,
}

export const Unchecked = {
  render: () => <Checkbox>Use TLS</Checkbox>,
}

export const Checked = {
  render: () => <Checkbox defaultChecked>Use TLS</Checkbox>,
}
