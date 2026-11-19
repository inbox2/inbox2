import { useState, useEffect } from 'react';
import styles from './ConnectionIndicator.module.css';

export default function ConnectionIndicator() {
  const [online, setOnline] = useState(navigator.onLine);

  useEffect(() => {
    const handleOnline = () => setOnline(true);
    const handleOffline = () => setOnline(false);
    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);
    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    };
  }, []);

  if (online) return null;

  return (
    <div className={styles.banner}>
      You’re offline. Your changes go through when you reconnect.
    </div>
  );
}
