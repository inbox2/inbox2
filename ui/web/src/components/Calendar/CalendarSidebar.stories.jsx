import { useEffect } from 'react'
import CalendarSidebar from './CalendarSidebar'
import useCalendarStore from '../../stores/calendarStore'

const accounts = [
  {
    key: 'acct_gmail',
    email_address: 'waseem@inbox2.dev',
    display_name: 'Waseem (Gmail)',
    provider_type: 'gmail',
    icon_url: null,
    avatar_url: null,
  },
  {
    key: 'acct_ms',
    email_address: 'waseem@contoso.com',
    display_name: 'Waseem (Microsoft)',
    provider_type: 'microsoft',
    icon_url: null,
    avatar_url: null,
  },
]

const calendars = [
  { id: 'cal_personal', name: 'Personal', color: '#4f8cff', source: 'google', _accountKey: 'acct_gmail', is_visible: true },
  { id: 'cal_team', name: 'Team', color: '#23c08a', source: 'google', _accountKey: 'acct_gmail', is_visible: true },
  { id: 'cal_work', name: 'Work', color: '#f0a020', source: 'microsoft', _accountKey: 'acct_ms', is_visible: true },
]

const iso = (hoursFromNow) => new Date(Date.now() + hoursFromNow * 3600_000).toISOString()

const events = [
  { id: 'evt_1', calendar_id: 'cal_personal', title: 'Standup', start_at: iso(0.3), end_at: iso(0.8), status: 'confirmed' },
  { id: 'evt_2', calendar_id: 'cal_team', title: 'Design review', start_at: iso(3), end_at: iso(4), status: 'confirmed' },
  { id: 'evt_3', calendar_id: 'cal_work', title: 'Client sync', start_at: iso(26), end_at: iso(27), status: 'confirmed' },
]

// Seed the zustand calendar store so the sidebar has calendars + events to show.
function SeedStore({ children }) {
  useEffect(() => {
    useCalendarStore.getState().setCalendars(calendars)
    useCalendarStore.getState().setEvents(events)
    useCalendarStore.getState().setActiveAccountKey(null)
  }, [])
  return children
}

export default {
  title: 'Components/Calendar',
  component: CalendarSidebar,
  decorators: [
    (Story) => (
      <SeedStore>
        <Story />
      </SeedStore>
    ),
  ],
}

export const Default = {
  render: () => <CalendarSidebar width={280} accounts={accounts} onNewEvent={() => {}} />,
}

export const Empty = {
  render: () => {
    useCalendarStore.getState().setCalendars([])
    useCalendarStore.getState().setEvents([])
    return <CalendarSidebar width={280} accounts={[]} onNewEvent={() => {}} />
  },
}
