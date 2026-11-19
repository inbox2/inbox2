// UI sound playback. Which sound plays (and whether sounds play at all) is driven
// by the user's choices in Settings → Sounds (lib/soundPref + lib/soundCatalog).
// Sounds: Mixkit (https://mixkit.co), free for commercial use.
import { getSoundPref } from './soundPref';
import { receiveSoundFile, sendSoundFile } from './soundCatalog';
import { invoke } from '@tauri-apps/api/core';
import { isTauri, getOS } from './tauri';

// One reusable Audio per file path, so repeated plays don't re-fetch.
const cache = new Map();

// macOS desktop plays through AudioToolbox system sounds: webview <audio> counts
// as media playback and makes AirPods auto-switch away from the iPhone.
const nativeSounds = isTauri() && getOS() === 'macos';

function play(file, volume) {
  if (!file) return;
  if (nativeSounds) {
    invoke('play_alert_sound', { file }).catch(() => {});
    return;
  }
  try {
    let audio = cache.get(file);
    if (!audio) {
      audio = new Audio(file);
      cache.set(file, audio);
    }
    audio.currentTime = 0;
    audio.volume = volume;
    audio.play();
  } catch {
    // Audio not available (e.g. before any user interaction)
  }
}

// Plays the chosen "new mail" sound. Gated by the master Sounds toggle.
export function playPing() {
  const { enabled, receive } = getSoundPref();
  if (!enabled) return;
  play(receiveSoundFile(receive), 0.5);
}

// A zone starting gets its own soft chime, so it never reads as new mail.
// Gated by the master Sounds toggle.
export const ZONE_SOUND_FILE = '/sounds/zone-chime.mp3';
export function playZoneChime() {
  if (!getSoundPref().enabled) return;
  play(ZONE_SOUND_FILE, 0.5);
}

// Plays the chosen "message sent" sound. Gated by the master Sounds toggle.
export function playSwoosh() {
  const { enabled, send } = getSoundPref();
  if (!enabled) return;
  play(sendSoundFile(send), 0.45);
}

// Plays a specific file regardless of preferences — used by the Settings preview
// buttons so the user can audition a sound before selecting it.
export function previewSound(file) {
  play(file, 0.6);
}
