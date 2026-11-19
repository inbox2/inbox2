import '../../styles/management.css'
import Skeleton from './Skeleton'
import styles from './Skeleton.stories.module.css'

export default {
  title: 'Disk/Skeleton',
  component: Skeleton,
  args: { count: 6 },
  render: (args) => <div className={`management ${styles.page}`}><Skeleton {...args} /></div>,
}

export const Rows = { args: { variant: 'row', count: 8 } }
export const Tiles = { args: { variant: 'tile' } }
export const Text = { args: { variant: 'text', count: 5 } }
