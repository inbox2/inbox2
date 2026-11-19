import DotMatrix from '../DotMatrix'
import styles from './DotMatrix.stories.module.css'

export default {
  title: 'Components/DotMatrix',
  component: DotMatrix,
}

export const Default = {
  render: () => (
    <div data-theme="dark" className={styles.container}>
      <DotMatrix />
    </div>
  ),
}

export const Light = {
  render: () => (
    <div data-theme="light" className={styles.container}>
      <DotMatrix />
    </div>
  ),
}
