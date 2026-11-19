import { useEffect } from 'react'
import NewMessagePopup from './NewMessagePopup'
import useNotificationStore from '../../stores/notificationStore'

// NewMessagePopup renders nothing unless the notification store holds entries, and
// it portals to document.body. Each story seeds the store on mount (and clears it
// on unmount) so the cards are visible.
function seed(notifications) {
  return function Seeded() {
    useEffect(() => {
      const store = useNotificationStore.getState()
      store.dismissAll()
      notifications.forEach((n) => store.show(n))
      return () => useNotificationStore.getState().dismissAll()
    }, [])
    return <NewMessagePopup />
  }
}

export default {
  title: 'Components/NewMessagePopup',
  component: NewMessagePopup,
}

export const SingleEvent = {
  render: seed([
    {
      key: 'conv_abc123',
      conversationId: 'conv_abc123',
      accountKey: 'gmail:team@inbox2.dev',
      eventType: 'new_message',
      from_address: 'Dana Lee <dana@partner.com>',
      email: 'dana@partner.com',
      subject: 'Q3 numbers — quick sync next week?',
      snippet: '<p>Are you free to walk through the Q3 numbers next Tuesday?</p>',
      priority: 'urgent',
    },
  ]),
}

export const AssignedEvent = {
  render: seed([
    {
      key: 'conv_def456',
      conversationId: 'conv_def456',
      accountKey: 'gmail:team@inbox2.dev',
      eventType: 'assigned',
      from_address: 'Marcus Vega <marcus@acme.com>',
      email: 'marcus@acme.com',
      subject: 'Contract renewal — needs your sign-off',
      snippet: 'Marcus assigned this thread to you.',
      priority: 'urgent',
    },
  ]),
}

export const MultipleEvents = {
  render: seed([
    {
      key: 'conv_111',
      conversationId: 'conv_111',
      accountKey: 'gmail:team@inbox2.dev',
      eventType: 'approval',
      from_address: 'Billing <billing@acme.com>',
      email: 'billing@acme.com',
      subject: 'Invoice #4821 awaiting approval',
      snippet: 'Approval required before the agent sends a reply.',
      priority: 'urgent',
    },
    {
      key: 'conv_222',
      conversationId: 'conv_222',
      accountKey: 'gmail:team@inbox2.dev',
      eventType: 'mention',
      from_address: 'Priya Nair <priya@partner.com>',
      email: 'priya@partner.com',
      subject: 'Re: launch checklist',
      snippet: 'Priya mentioned you in a comment.',
      priority: 'urgent',
    },
  ]),
}
