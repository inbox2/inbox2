import Button from './Button'
import Icon from '../Icon'

export default {
  title: 'Components/Button',
  component: Button,
}

export const Primary = {
  render: () => <Button>Primary</Button>,
}

export const PrimaryWithIcon = {
  render: () => (
    <Button>
      <Icon name="square.and.pencil" size={14} />
      Compose
    </Button>
  ),
}

export const Secondary = {
  render: () => <Button variant="secondary">Secondary</Button>,
}

export const Ghost = {
  render: () => <Button variant="ghost">Ghost</Button>,
}

export const Disabled = {
  render: () => <Button disabled>Disabled</Button>,
}
