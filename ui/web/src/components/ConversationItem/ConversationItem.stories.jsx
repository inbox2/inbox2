import ConversationItem from './ConversationItem'
import { QUADRANTS } from '../../lib/priority'

export default {
  title: 'Components/ConversationItem',
  component: ConversationItem,
}

export const Unread = {
  args: {
    sender: 'Sarah Chen',
    subject: 'Q3 Revenue Forecast — Updated Numbers',
    snippet: 'Hi team, I\'ve updated the revenue projections...',
    time: '10:23 AM',
    unread: true,
    tags: [{ name: 'Finance', bg: '#8090a8', fg: '#1a1e28', style: 'square' }],
    assignee: 'Waseem Sadiq',
    hasAttachment: true,
    count: 4,
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}

export const Read = {
  args: {
    sender: 'Alex Kim',
    subject: 'Partnership proposal — Integration opportunity',
    snippet: 'Hi Waseem, I\'d love to explore a potential integration...',
    time: 'May 20',
    count: 3,
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}

export const WithViewers = {
  args: {
    sender: 'Maria Lopez',
    subject: 'RE: Support request — Login issues',
    snippet: 'Thanks for the quick response!',
    time: 'Yesterday',
    tags: [{ name: 'Support', bg: '#b8a0b8', fg: '#22182a', style: 'square' }],
    assignee: 'Maria Lopez',
    count: 6,
    viewers: ['Alex Kim'],
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}

export const TriagedPriority = {
  args: {
    sender: 'CTO Office',
    subject: 'Server outage — Immediate action needed',
    snippet: 'Production DB is experiencing high latency...',
    time: '8:02 AM',
    unread: true,
    quadrant: QUADRANTS.DO_FIRST,
    count: 2,
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}

export const TriagedSchedule = {
  args: {
    sender: 'Product Team',
    subject: 'Roadmap review — Q4 planning',
    snippet: 'Let\'s schedule a call to discuss the upcoming...',
    time: 'May 22',
    quadrant: QUADRANTS.SCHEDULE,
    tags: [{ name: 'Planning', bg: '#6ea8d9' }],
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}

export const TriagedDelegate = {
  args: {
    sender: 'Support Bot',
    subject: 'Ticket #4821 — Password reset request',
    snippet: 'User john@example.com has requested a password...',
    time: '2:15 PM',
    quadrant: QUADRANTS.DELEGATE,
    count: 1,
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}
