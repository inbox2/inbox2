import ConnectionIndicator from './ConnectionIndicator'
import styles from './ConnectionIndicator.module.css'

export default {
  title: 'Components/ConnectionIndicator',
  component: ConnectionIndicator,
}

// The component only renders when navigator.onLine is false,
// so the Online story shows nothing (correct behavior).
export const Online = {}

// Show the offline banner by rendering the styled markup directly,
// since navigator.onLine cannot be overridden in Storybook.
export const Offline = {
  render: () => (
    <div data-theme="dark">
      <div className={styles.banner}>
        Connection lost — changes will sync when you reconnect
      </div>
    </div>
  ),
}
