import { DndContext } from '@dnd-kit/core'
import ListViewColumns from './ListViewColumns'

function makeConv(id, accountKey, subject, from, opts = {}) {
  return {
    id,
    accountKey,
    subject,
    from_address: from,
    snippet: 'Preview text...',
    updated_at: new Date(Date.now() - Math.random() * 86400000).toISOString(),
    read: true,
    has_attachment: false,
    ...opts,
  }
}

const mockConversations = [
  makeConv('c1', 'org_demo', 'Q3 Planning', 'Alice <alice@inbox2.dev>'),
  makeConv('c2', 'org_demo', 'Bug report #412', 'Bob <bob@inbox2.dev>', { read: false }),
  makeConv('c3', 'gmail_1', 'Dinner tonight?', 'Carol <carol@gmail.com>'),
  makeConv('c4', 'gmail_1', 'Flight confirmation', 'airline@example.com', { has_attachment: true }),
  makeConv('c5', 'outlook_1', 'Sprint retro notes', 'Dave <dave@company.com>'),
]

const mockChannelStates = {
  org_demo: { account: { key: 'org_demo', display_name: 'inbox2 Team' }, enabled: true },
  gmail_1: { account: { key: 'gmail_1', display_name: 'Personal' }, enabled: true },
  outlook_1: { account: { key: 'outlook_1', display_name: 'Work' }, enabled: true },
}

const mockAccounts = [
  { key: 'org_demo', display_name: 'inbox2 Team' },
  { key: 'gmail_1', display_name: 'Personal' },
  { key: 'outlook_1', display_name: 'Work' },
]

const noop = () => {}

export default {
  title: 'Components/ListViewColumns',
  component: ListViewColumns,
  decorators: [(Story) => <DndContext><Story /></DndContext>],
}

export const Default = {
  args: {
    conversations: mockConversations,
    channelStates: mockChannelStates,
    accounts: mockAccounts,
    selectedId: null,
    onSelect: noop,
    onContextMenu: noop,
    onHover: noop,
    onHoverEnd: noop,
    unreadOnly: false,
  },
}

export const WithSelection = {
  args: {
    conversations: mockConversations,
    channelStates: mockChannelStates,
    accounts: mockAccounts,
    selectedId: 'c2',
    onSelect: noop,
    onContextMenu: noop,
    onHover: noop,
    onHoverEnd: noop,
    unreadOnly: false,
  },
}

export const UnreadOnly = {
  args: {
    conversations: mockConversations,
    channelStates: mockChannelStates,
    accounts: mockAccounts,
    selectedId: null,
    onSelect: noop,
    onContextMenu: noop,
    onHover: noop,
    onHoverEnd: noop,
    unreadOnly: true,
  },
}
