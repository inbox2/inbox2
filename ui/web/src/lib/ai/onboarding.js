// One-time AI onboarding modal dismissal state. Kept in its own module (not the
// component file) so it can be shared without breaking React Fast Refresh.

import { AI_ONBOARDING_DISMISSED as DISMISSED_KEY } from '../storageKeys';

export function wasAIOnboardingDismissed() {
  return localStorage.getItem(DISMISSED_KEY) === '1';
}

export function markAIOnboardingDismissed() {
  localStorage.setItem(DISMISSED_KEY, '1');
}
