import Icon, { ICONS } from './Icon'

export default {
  title: 'Components/Icon',
  component: Icon,
}

export const Default = { args: { name: 'tray.fill', size: 18 } }
export const Large = { args: { name: 'magnifyingglass', size: 32 } }

export const Gallery = {
  render: () => (
    <div data-theme="dark">
      {Object.keys(ICONS).map(name => (
        <span key={name} title={name}>
          <Icon name={name} size={24} />{' '}
        </span>
      ))}
    </div>
  ),
}

export const GalleryWithLabels = {
  render: () => (
    <div data-theme="dark">
      {Object.keys(ICONS).map(name => (
        <div key={name}>
          <Icon name={name} size={20} />
          <span>{' '}{name}</span>
        </div>
      ))}
    </div>
  ),
}
