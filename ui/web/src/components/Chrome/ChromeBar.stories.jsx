import { MemoryRouter, Route, Routes } from 'react-router'
import { AuthContext } from '../../hooks/AuthProvider'
import ChromeBar from './ChromeBar'

const noop = () => {}

const SAMPLE_ACCOUNTS = [
  { key: 'demo', display_name: 'Demo Org', email_address: 'demo.org', provider_type: 'inbox2', status: 'connected' },
  { key: 'gmail-1', display_name: 'Work', email_address: 'alice@gmail.com', provider_type: 'gmail', status: 'connected' },
  { key: 'ms-1', display_name: 'Corp', email_address: 'alice@outlook.com', provider_type: 'microsoft', status: 'connected' },
]

export default {
  title: 'Components/ChromeBar',
  component: ChromeBar,
  decorators: [
    (Story) => (
      <MemoryRouter initialEntries={['/demo/mail']}>
        <Routes>
          {/* An admin, so the avatar's apps include the console. */}
          <Route path="/:orgSlug/*" element={<AuthContext.Provider value={{ user: { username: 'sara', email: 'sara@example.com' }, organizations: [{ id: 'org_demo', role: 'owner' }] }}><Story /></AuthContext.Provider>} />
        </Routes>
      </MemoryRouter>
    ),
  ],
}

export const UnifiedActive = {
  args: {
    activeTab: 'mail',
    accounts: SAMPLE_ACCOUNTS,
    onNotifications: noop,
    searchProps: { value: '', onChange: noop, onKeyDown: noop },
  },
}

export const ChannelActive = {
  args: {
    activeTab: 'mail',
    activeAccountKey: 'gmail-1',
    accounts: SAMPLE_ACCOUNTS,
    onNotifications: noop,
    searchProps: { value: '', onChange: noop, onKeyDown: noop },
  },
}

export const ExplorerActive = {
  args: {
    activeTab: 'explorer',
    accounts: SAMPLE_ACCOUNTS,
    onNotifications: noop,
    searchProps: { value: '', onChange: noop, onKeyDown: noop },
  },
}

export const WithSearch = {
  args: {
    activeTab: 'mail',
    accounts: SAMPLE_ACCOUNTS,
    onNotifications: noop,
    searchProps: { value: 'invoice from acme', onChange: noop, onKeyDown: noop },
  },
}
