import { DndContext } from '@dnd-kit/core'
import MiniCard from './MiniCard'

const mockConv = {
  id: 'conv_1',
  from_address: 'Alice Chen <alice@example.com>',
  subject: 'Q3 Planning Meeting',
  snippet: 'Let me know your availability for next week.',
  updated_at: new Date(Date.now() - 3600000).toISOString(),
  read: true,
}

export default {
  title: 'Components/MiniCard',
  component: MiniCard,
  decorators: [(Story) => <DndContext><Story /></DndContext>],
}

export const Default = {
  args: { conv: mockConv },
}

export const Unread = {
  args: { conv: { ...mockConv, id: 'conv_2', read: false } },
}

export const Active = {
  args: { conv: mockConv, active: true },
}

export const HiddenAvatar = {
  args: { conv: mockConv, hideAvatar: true },
}
