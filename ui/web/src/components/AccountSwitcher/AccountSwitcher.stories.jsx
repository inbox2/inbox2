import { DndContext } from '@dnd-kit/core'
import AccountSwitcher from './AccountSwitcher'

const mockAccounts = [
  { key: 'org_demo', provider_type: 'inbox2', display_name: 'inbox2 Team', email_address: 'waseem@inbox2.dev', status: 'active' },
  { key: 'gmail_1', provider_type: 'gmail', display_name: 'Personal Gmail', email_address: 'waseem@gmail.com', status: 'active' },
  { key: 'outlook_1', provider_type: 'microsoft', display_name: 'Work Outlook', email_address: 'wsadiq@company.com', status: 'active' },
  { key: 'imap_1', provider_type: 'imap', display_name: 'Fastmail', email_address: 'waseem@fastmail.com', status: 'error' },
]

const noop = () => {}

export default {
  title: 'Components/AccountSwitcher',
  component: AccountSwitcher,
  decorators: [(Story) => <DndContext><Story /></DndContext>],
}

export const Default = {
  args: {
    accounts: mockAccounts,
    activeKey: 'org_demo',
    onSwitch: noop,
    onAddAccount: noop,
    onUnified: noop,
    isUnified: false,
    onReorder: noop,
  },
}

export const UnifiedActive = {
  args: {
    accounts: mockAccounts,
    activeKey: null,
    onSwitch: noop,
    onAddAccount: noop,
    onUnified: noop,
    isUnified: true,
    onReorder: noop,
  },
}

export const SingleAccount = {
  args: {
    accounts: [mockAccounts[0]],
    activeKey: 'org_demo',
    onSwitch: noop,
    onAddAccount: noop,
    onUnified: noop,
    isUnified: false,
    onReorder: noop,
  },
}
