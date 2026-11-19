import StreamItem from './StreamItem'

export default {
  title: 'Components/StreamItem',
  component: StreamItem,
}

export const Default = { args: { text: 'Waseem replied', time: '10:45 AM' } }
export const Accent = { args: { text: 'Route: finance@ → WS', time: '10:23 AM', accent: true } }

export const Stream = {
  render: () => (
    <div data-theme="dark">
      <StreamItem text="Waseem replied" time="10:45 AM" />
      <StreamItem text="Route: finance@ → WS" time="10:23 AM" accent />
      <StreamItem text="Sarah sent message" time="10:23 AM" />
      <StreamItem text="AI summarized thread" time="10:24 AM" accent />
      <StreamItem text="Alex opened thread" time="10:30 AM" />
    </div>
  ),
}
