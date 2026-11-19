import { MemoryRouter } from 'react-router'
import MessageCard from './MessageCard'
import DraftProvider from '../../hooks/DraftProvider'

export default {
  title: 'Components/MessageCard',
  component: MessageCard,
  decorators: [(Story) => <MemoryRouter><DraftProvider orgId={null}><Story /></DraftProvider></MemoryRouter>],
}

export const Default = {
  args: {
    sender: 'Sarah Chen',
    email: 'sarah@acme.co',
    time: 'Today 10:23 AM',
    body: '<p>Hi team,</p><p>I\'ve updated the revenue projections. Key highlights:</p><ul><li>Q3 projected revenue: <strong>$2.4M</strong> (up 18%)</li><li>340 new accounts added</li></ul><p>Best,<br/>Sarah</p>',
    attachments: [{ name: 'Q3-Forecast.xlsx', size: '245 KB' }],
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}

export const NoAttachments = {
  args: {
    sender: 'Alex Kim',
    email: 'alex@partner.io',
    time: 'Yesterday',
    body: '<p>Thanks for the update. Looks good to me!</p>',
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}
