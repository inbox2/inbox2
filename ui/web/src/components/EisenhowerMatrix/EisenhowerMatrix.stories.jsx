import { DndContext } from '@dnd-kit/core'
import EisenhowerMatrix from './EisenhowerMatrix'

function makeConv(id, subject, from, opts = {}) {
  return {
    id,
    subject,
    from_address: from,
    snippet: 'Preview text for this conversation...',
    updated_at: new Date(Date.now() - Math.random() * 86400000).toISOString(),
    read: true,
    triaged: true,
    urgent: false,
    important: false,
    ...opts,
  }
}

const mockConversations = [
  makeConv('c1', 'Server outage', 'ops@example.com', { urgent: true, important: true }),
  makeConv('c2', 'Customer escalation', 'support@example.com', { urgent: true, important: true }),
  makeConv('c3', 'CEO review deck', 'alice@example.com', { urgent: true, important: false }),
  makeConv('c4', 'Vendor renewal deadline', 'vendor@example.com', { urgent: true, important: false }),
  makeConv('c5', 'Architecture RFC', 'bob@example.com', { urgent: false, important: true }),
  makeConv('c6', 'Hiring pipeline review', 'hr@example.com', { urgent: false, important: true }),
  makeConv('c7', 'Team lunch poll', 'carol@example.com', { urgent: false, important: false }),
  makeConv('c8', 'Newsletter subscription', 'news@example.com', { urgent: false, important: false }),
]

const noop = () => {}

export default {
  title: 'Components/EisenhowerMatrix',
  component: EisenhowerMatrix,
  decorators: [(Story) => <DndContext><Story /></DndContext>],
}

export const Default = {
  args: {
    conversations: mockConversations,
    onCardClick: noop,
    onContextMenu: noop,
    onHover: noop,
    onHoverEnd: noop,
    isDragging: false,
  },
}

export const DragActive = {
  args: {
    conversations: mockConversations,
    onCardClick: noop,
    onContextMenu: noop,
    onHover: noop,
    onHoverEnd: noop,
    isDragging: true,
  },
}

export const Empty = {
  args: {
    conversations: [],
    onCardClick: noop,
    onContextMenu: noop,
    onHover: noop,
    onHoverEnd: noop,
    isDragging: false,
  },
}
