import { useEffect } from 'react';
import { MemoryRouter } from 'react-router';
import NotificationPanel from './NotificationPanel';
import useNotificationStore from '../../stores/notificationStore';

const SAMPLE_HISTORY = [
  {
    _alertId: 1,
    eventType: 'reply',
    eventLabel: 'Customer replied',
    eventColor: 'waiting',
    from_address: 'Sarah Chen <sarah@acme.com>',
    subject: 'Q4 Budget Review',
    arrivedAt: Date.now() - 300000,
  },
  {
    _alertId: 2,
    eventType: 'assigned',
    eventLabel: 'Assigned to you',
    eventColor: 'assigned',
    from_address: 'Alex Kim <alex@company.com>',
    subject: 'Support ticket #412',
    arrivedAt: Date.now() - 900000,
  },
  {
    _alertId: 3,
    eventType: 'mention',
    eventLabel: 'Mentioned',
    eventColor: 'mention',
    from_address: 'Alex Kim <alex@company.com>',
    subject: 'Deploy checklist',
    arrivedAt: Date.now() - 2700000,
  },
  {
    _alertId: 4,
    eventType: 'new_message',
    eventLabel: 'New message',
    eventColor: 'primary',
    from_address: 'noreply@acme.com',
    subject: 'Domain verified: acme.com',
    arrivedAt: Date.now() - 5400000,
  },
];

function SeedStore({ children }) {
  useEffect(() => {
    useNotificationStore.setState({ history: SAMPLE_HISTORY });
    return () => useNotificationStore.setState({ history: [] });
  }, []);
  return children;
}

export default {
  title: 'Components/NotificationPanel',
  component: NotificationPanel,
  decorators: [
    (Story) => (
      <div data-theme="dark">
        <MemoryRouter><SeedStore><Story /></SeedStore></MemoryRouter>
      </div>
    ),
  ],
};

export const Open = {
  args: {
    open: true,
    onClose: () => {},
  },
};

export const Empty = {
  args: {
    open: true,
    onClose: () => {},
  },
  decorators: [
    (Story) => {
      useEffect(() => {
        useNotificationStore.setState({ history: [] });
      }, []);
      return <Story />;
    },
  ],
};
