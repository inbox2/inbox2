import { useState, useEffect, useRef } from 'react';
import Icon from '../Icon';
import Chip from '../Chip';
import IconButton from '../IconButton';
import { isGenerativeReady, generateSmartReplies } from '../../lib/ai';
import styles from './SmartReplyBar.module.css';

/**
 * Smart Reply suggestions bar — appears below a message when generative AI is ready.
 * Shows 3 short reply options the user can click to pre-fill the composer.
 *
 * @param {Object} props
 * @param {string} props.emailText - Email body to generate replies for
 * @param {string} props.senderName - Sender of the email
 * @param {(reply: string) => void} props.onSelectReply - Called when user picks a reply
 */
export default function SmartReplyBar({ emailText, senderName, onSelectReply }) {
  const [replies, setReplies] = useState(null); // null = loading, [] = no results
  const [dismissed, setDismissed] = useState(false);
  const fetchedRef = useRef(null);

  useEffect(() => {
    if (!emailText || !isGenerativeReady() || dismissed) return;
    if (fetchedRef.current === emailText) return;

    let cancelled = false;
    fetchedRef.current = emailText;

    (async () => {
      const result = await generateSmartReplies(emailText, senderName);
      if (cancelled) return;
      setReplies(result);
    })();

    return () => { cancelled = true; };
  }, [emailText, senderName, dismissed]);

  if (dismissed) return null;
  if (!isGenerativeReady()) return null;
  if (!replies || replies.length === 0) return null;

  return (
    <div className={styles.bar}>
      <div className={styles.label}>
        <Icon name="bolt.fill" size={12} className={styles.icon} />
        <span>Smart replies</span>
      </div>
      <div className={styles.replies}>
        {replies.map((reply, i) => (
          <Chip
            key={i}
            onClick={() => onSelectReply?.(reply)}
          >
            {reply}
          </Chip>
        ))}
      </div>
      <IconButton
        icon="xmark"
        size="sm"
        iconSize={12}
        onClick={() => setDismissed(true)}
        aria-label="Dismiss smart replies"
      />
    </div>
  );
}
