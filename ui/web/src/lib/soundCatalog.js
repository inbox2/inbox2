// Catalog of selectable UI sounds — the single source of truth for which sounds
// exist and which file each maps to. Referenced by the Sounds settings panel
// (dropdowns + preview) and by notificationSound.js (playback). Add a sound by
// dropping the mp3 in public/sounds/ and adding one entry here.
//
// All Mixkit sounds are from https://mixkit.co — free for commercial use under
// the Mixkit Sound Effects Free License (no attribution required, but credited
// in the Sounds settings panel). The original "beep" notification is also Mixkit.

export const RECEIVE_SOUNDS = [
  { id: 'beep', label: 'Beep', file: '/sounds/notification.mp3', credit: 'Mixkit' },
  { id: 'retro-game', label: 'Retro game', file: '/sounds/mixkit-unlock-game-notification.mp3', credit: 'Mixkit' },
  { id: 'epic-orchestra', label: 'Epic orchestra transition', file: '/sounds/mixkit-epic-orchestra-transition.mp3', credit: 'Mixkit' },
  { id: 'bass-pulse', label: 'Mysterious bass pulse', file: '/sounds/mixkit-mysterious-bass-pulse.mp3', credit: 'Mixkit' },
  { id: 'trumpet-fanfare', label: 'Trumpet fanfare', file: '/sounds/mixkit-trumpet-fanfare.mp3', credit: 'Mixkit' },
  { id: 'telephone', label: 'Vintage telephone ringtone', file: '/sounds/mixkit-vintage-telephone-ringtone.mp3', credit: 'Mixkit' },
];

export const SEND_SOUNDS = [
  { id: 'air-woosh', label: 'Air woosh', file: '/sounds/mixkit-air-woosh.mp3', credit: 'Mixkit' },
  { id: 'flute', label: 'Melodical flute', file: '/sounds/mixkit-melodical-flute-notification.mp3', credit: 'Mixkit' },
  { id: 'punch', label: 'Martial arts fast punch', file: '/sounds/mixkit-martial-arts-fast-punch.mp3', credit: 'Mixkit' },
  { id: 'futuristic-hum', label: 'Technological futuristic hum', file: '/sounds/mixkit-technological-futuristic-hum.mp3', credit: 'Mixkit' },
];

export const DEFAULT_RECEIVE_SOUND = 'beep';
export const DEFAULT_SEND_SOUND = 'air-woosh';

function resolve(list, id, fallbackId) {
  return (list.find((s) => s.id === id) || list.find((s) => s.id === fallbackId))?.file || null;
}

/** Resolve the file path for a receive-sound id (falls back to the default). */
export function receiveSoundFile(id) {
  return resolve(RECEIVE_SOUNDS, id, DEFAULT_RECEIVE_SOUND);
}

/** Resolve the file path for a send-sound id (falls back to the default). */
export function sendSoundFile(id) {
  return resolve(SEND_SOUNDS, id, DEFAULT_SEND_SOUND);
}
