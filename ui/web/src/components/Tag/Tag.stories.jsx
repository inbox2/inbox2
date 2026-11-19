import Tag from './Tag'
import { TAG_PRESETS } from './presets'

export default {
  title: 'Components/Tag',
  component: Tag,
}

export const Default = { args: { children: 'Dev', bg: TAG_PRESETS.dev.bg, fg: TAG_PRESETS.dev.fg } }
export const Square = { args: { children: 'Finance', variant: 'square', bg: TAG_PRESETS.finance.bg, fg: TAG_PRESETS.finance.fg } }
export const Support = { args: { children: 'Support', variant: 'square', bg: TAG_PRESETS.support.bg, fg: TAG_PRESETS.support.fg } }
export const Billing = { args: { children: 'Billing', bg: TAG_PRESETS.billing.bg, fg: TAG_PRESETS.billing.fg } }
export const System = { args: { children: 'System', bg: TAG_PRESETS.system.bg, fg: TAG_PRESETS.system.fg } }
export const Open = { args: { children: 'Open', variant: 'square', bg: TAG_PRESETS.open.bg, fg: TAG_PRESETS.open.fg } }
export const Urgent = { args: { children: 'Urgent', variant: 'square', bg: TAG_PRESETS.urgent.bg, fg: TAG_PRESETS.urgent.fg } }
export const Pending = { args: { children: 'Pending', variant: 'square', bg: TAG_PRESETS.pending.bg, fg: TAG_PRESETS.pending.fg } }

export const AllPresets = {
  render: () => (
    <div data-theme="dark">
      {Object.entries(TAG_PRESETS).map(([name, { bg, fg }]) => (
        <span key={name}>
          <Tag bg={bg} fg={fg} variant="square">{name}</Tag>{' '}
        </span>
      ))}
    </div>
  ),
}
