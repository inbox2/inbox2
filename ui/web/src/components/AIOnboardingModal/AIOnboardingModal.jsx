import { useState, useEffect } from 'react';
import AISetup from '../AISetup';
import Modal from '../Modal/Modal';
import { hasAIConsent } from '../../lib/ai';
import { wasAIOnboardingDismissed, markAIOnboardingDismissed } from '../../lib/ai/onboarding';
import styles from './AIOnboardingModal.module.css';

/**
 * One-time AI onboarding modal — shown on first inbox load in Tauri
 * if the user hasn't already set up or dismissed AI features.
 */
export default function AIOnboardingModal() {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    // Only show if: not already consented, not previously dismissed
    if (hasAIConsent() || wasAIOnboardingDismissed()) return;
    // Small delay so it doesn't flash immediately on page load
    const timer = setTimeout(() => setVisible(true), 1500);
    return () => clearTimeout(timer);
  }, []);

  const handleComplete = () => {
    markAIOnboardingDismissed();
    setVisible(false);
  };

  const handleDismiss = () => {
    markAIOnboardingDismissed();
    setVisible(false);
  };

  return (
    <Modal open={visible} onClose={handleDismiss} className={styles.modal}>
      <AISetup onComplete={handleComplete} />
    </Modal>
  );
}
