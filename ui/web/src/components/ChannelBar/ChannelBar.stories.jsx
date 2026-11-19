import ChannelBar from './ChannelBar'

const mockChannelStates = {
  org_demo: { account: { key: 'org_demo', provider_type: 'inbox2', display_name: 'inbox2 Team', email_address: 'team@inbox2.dev' }, enabled: true },
  gmail_1: { account: { key: 'gmail_1', provider_type: 'gmail', display_name: 'Personal', email_address: 'waseem@gmail.com' }, enabled: true },
  outlook_1: { account: { key: 'outlook_1', provider_type: 'microsoft', display_name: 'Work', email_address: 'wsadiq@company.com' }, enabled: false },
}

const mockConversations = [
  { id: '1', accountKey: 'org_demo', read: false, subject: 'Test' },
  { id: '2', accountKey: 'org_demo', read: false, subject: 'Test 2' },
  { id: '3', accountKey: 'org_demo', read: true, subject: 'Test 3' },
  { id: '4', accountKey: 'gmail_1', read: false, subject: 'Test 4' },
]

const mockAccounts = [
  { key: 'org_demo', provider_type: 'inbox2', display_name: 'inbox2 Team' },
  { key: 'gmail_1', provider_type: 'gmail', display_name: 'Personal' },
  { key: 'outlook_1', provider_type: 'microsoft', display_name: 'Work' },
]

const noop = () => {}

export default {
  title: 'Components/ChannelBar',
  component: ChannelBar,
}

export const Default = {
  args: {
    channelStates: mockChannelStates,
    onToggle: noop,
    conversations: mockConversations,
    unreadOnly: false,
    onToggleUnread: noop,
    accounts: mockAccounts,
    onSwitchAccount: noop,
    onAddAccount: noop,
    viewMode: 'grid',
    onViewModeChange: noop,
  },
}

export const UnreadOnly = {
  args: {
    channelStates: mockChannelStates,
    onToggle: noop,
    conversations: mockConversations,
    unreadOnly: true,
    onToggleUnread: noop,
    accounts: mockAccounts,
    onSwitchAccount: noop,
    onAddAccount: noop,
    viewMode: 'grid',
    onViewModeChange: noop,
  },
}

export const ListView = {
  args: {
    channelStates: mockChannelStates,
    onToggle: noop,
    conversations: mockConversations,
    unreadOnly: false,
    onToggleUnread: noop,
    accounts: mockAccounts,
    onSwitchAccount: noop,
    onAddAccount: noop,
    viewMode: 'list',
    onViewModeChange: noop,
  },
}
