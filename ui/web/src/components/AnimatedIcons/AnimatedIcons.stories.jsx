import { useRef } from 'react'
import FlameIcon from './FlameIcon'
import UserPlusIcon from './UserPlusIcon'
import AlarmClockIcon from './AlarmClockIcon'
import ClockIcon from './ClockIcon'
import styles from './AnimatedIcons.stories.module.css'

export default {
  title: 'Components/AnimatedIcons',
}

function HoverWrapper({ children }) {
  const ref = useRef(null)
  return (
    <div
      className={styles.hoverWrapper}
      role="presentation"
      onMouseEnter={() => ref.current?.startAnimation?.()}
      onMouseLeave={() => ref.current?.stopAnimation?.()}
    >
      {children(ref)}
    </div>
  )
}

export const Flame = {
  render: () => (
    <HoverWrapper>
      {(ref) => <FlameIcon ref={ref} size={32} color="var(--text-primary)" />}
    </HoverWrapper>
  ),
}

export const UserPlus = {
  render: () => (
    <HoverWrapper>
      {(ref) => <UserPlusIcon ref={ref} size={32} color="var(--text-primary)" />}
    </HoverWrapper>
  ),
}

export const AlarmClock = {
  render: () => (
    <HoverWrapper>
      {(ref) => <AlarmClockIcon ref={ref} size={32} color="var(--text-primary)" />}
    </HoverWrapper>
  ),
}

export const Clock = {
  render: () => (
    <HoverWrapper>
      {(ref) => <ClockIcon ref={ref} size={32} color="var(--text-primary)" />}
    </HoverWrapper>
  ),
}

export const AllIcons = {
  render: () => (
    <div className={styles.row}>
      <HoverWrapper>
        {(ref) => <FlameIcon ref={ref} size={32} color="var(--text-primary)" />}
      </HoverWrapper>
      <HoverWrapper>
        {(ref) => <UserPlusIcon ref={ref} size={32} color="var(--text-primary)" />}
      </HoverWrapper>
      <HoverWrapper>
        {(ref) => <AlarmClockIcon ref={ref} size={32} color="var(--text-primary)" />}
      </HoverWrapper>
      <HoverWrapper>
        {(ref) => <ClockIcon ref={ref} size={32} color="var(--text-primary)" />}
      </HoverWrapper>
    </div>
  ),
}
