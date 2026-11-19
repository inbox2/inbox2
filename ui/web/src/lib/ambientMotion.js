// Ambient motion (the backdrop, looping CSS animations) runs only while someone is
// here: the window is visible, focused, and had input in the last IDLE_MS. A window
// left open and focused overnight otherwise animates forever, and on a machine
// without GPU compositing (WebKitGTK on llvmpipe) every frame is drawn by the CPU:
// one such window held 8 cores for 2.5 days. While idle, looping animations pause;
// one-shot ones (a card fading in) always finish.
import { useSyncExternalStore } from 'react'
import log from './log'
import { isTauri } from './tauri'

export const IDLE_MS = 60_000
const INPUT = ['pointermove', 'pointerdown', 'keydown', 'wheel', 'touchstart']

let lastInput = Date.now()
let active = true
let timer = null
let started = false
const listeners = new Set()

function compute() {
  return document.visibilityState === 'visible' && document.hasFocus() && Date.now() - lastInput < IDLE_MS
}

function update() {
  clearTimeout(timer)
  const next = compute()
  if (next) timer = setTimeout(update, IDLE_MS - (Date.now() - lastInput) + 50)
  if (next === active) return
  active = next
  pauseLoops(!active)
  listeners.forEach((fn) => fn())
}

// Only infinite ones: these are the spinners, pulses and tickers left running.
const paused = new Set()
function pauseLoop(a) {
  if (a.playState === 'running' && a.effect?.getTiming().iterations === Infinity) {
    a.pause()
    paused.add(a)
  }
}
function pauseLoops(pause) {
  if (pause) {
    for (const a of document.getAnimations?.() || []) pauseLoop(a)
  } else {
    paused.forEach((a) => a.play())
    paused.clear()
  }
}

// A loop that starts while nobody is here (a spinner mounting, or launch in an
// unfocused window) is paused as it starts.
function onAnimationStart(e) {
  if (active) return
  for (const a of e.target.getAnimations?.() || []) if (a.animationName === e.animationName) pauseLoop(a)
}

// Cheap on the hot path: while active, input only moves the deadline the timer checks.
function onInput() {
  lastInput = Date.now()
  if (!active) update()
}

export function startAmbientMotion() {
  if (started || typeof document === 'undefined') return
  started = true
  INPUT.forEach((e) => window.addEventListener(e, onInput, { capture: true, passive: true }))
  document.addEventListener('visibilitychange', update)
  window.addEventListener('focus', onInput)
  window.addEventListener('blur', update)
  document.addEventListener('animationstart', onAnimationStart, true)
  update()
  detectSoftwareRendering()
}

export function subscribe(fn) {
  startAmbientMotion()
  listeners.add(fn)
  return () => listeners.delete(fn)
}

export const isAmbientActive = () => active

export function useAmbientActive() {
  return useSyncExternalStore(subscribe, isAmbientActive, () => true)
}

// No GPU: every frame is drawn by the CPU, so backdrops hold still. WebKit reports a
// made-up WebGL renderer ("Apple GPU" on llvmpipe), so the desktop app asks natively.
let software = false
export const softwareRendering = () => software

export function useSoftwareRendering() {
  return useSyncExternalStore(subscribe, softwareRendering, () => false)
}

function detectSoftwareRendering() {
  if (!isTauri()) return
  import('@tauri-apps/api/core')
    .then(({ invoke }) => invoke('software_rendering'))
    .then((yes) => {
      if (!yes) return
      software = true
      log.info('Ambient', 'no GPU: backdrops hold still')
      listeners.forEach((fn) => fn())
    })
    .catch(() => {})
}
