import { Link } from 'react-router';
import styles from '../../pages/system/system.module.css';

export default function StatusPage({ code, title, message, linkTo, linkLabel, actionLabel, onAction }) {
  return (
    <div className={styles.systemPage}>
      <div className={styles.systemCode}>{code}</div>
      <h1 className={styles.systemTitle}>{title}</h1>
      <p className={styles.systemMessage}>{message}</p>
      {onAction ? (
        <button type="button" className={styles.systemLink} onClick={onAction}>{actionLabel}</button>
      ) : linkTo ? (
        <Link to={linkTo} className={styles.systemLink}>{linkLabel}</Link>
      ) : null}
    </div>
  );
}
