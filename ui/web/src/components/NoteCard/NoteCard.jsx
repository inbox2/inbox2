import Avatar from '../Avatar'
import styles from './NoteCard.module.css'

export default function NoteCard({ author, time, children }) {
  return (
    <div className={styles.card}>
      <div className={styles.label}>Internal note</div>
      <div className={styles.header}>
        <Avatar name={author} size={28} />
        <div className={styles.author}>{author.split(' ')[0]}</div>
        <span className={styles.time}>{time}</span>
      </div>
      <div className={styles.body}>{children}</div>
    </div>
  )
}
