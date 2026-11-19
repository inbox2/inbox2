import Icon from '../Icon'
import styles from './StreamItem.module.css'

// `name` (optional) is the actor prefix, set in mono so it reads apart from the
// action text that follows it.
export default function StreamItem({ text, name, time, accent, onClick }) {
  if (onClick) {
    return (
      <button type="button" className={styles.itemButton} onClick={onClick}>
        <Icon name="chevron.right" size={9} className={styles.chevron} />
        <span className={accent ? styles.textAccent : styles.text}>
          {name && <span className={styles.name}>{name}</span>}{text}
        </span>
        <span className={styles.time}>{time}</span>
      </button>
    )
  }
  return (
    <div className={styles.item}>
      <span className={accent ? styles.textAccent : styles.text}>{text}</span>
      <span className={styles.time}>{time}</span>
    </div>
  )
}
