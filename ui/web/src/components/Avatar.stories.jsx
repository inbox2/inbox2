import Avatar from './Avatar'

export default {
  title: 'Components/Avatar',
  component: Avatar,
}

export const Small = { args: { name: 'Sarah Chen', size: 18 } }
export const Default = { args: { name: 'Waseem Sadiq', size: 28 } }
export const Large = { args: { name: 'Alex Kim', size: 32 } }

export const Gallery = {
  render: () => (
    <div data-theme="dark">
      {['Sarah Chen', 'Waseem Sadiq', 'Alex Kim', 'Maria Lopez', 'GitHub', 'Stripe'].map(name => (
        <span key={name}>
          <Avatar name={name} size={32} />{' '}
        </span>
      ))}
    </div>
  ),
}
