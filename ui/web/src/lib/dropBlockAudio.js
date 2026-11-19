// DropBlock audio — a tiny procedural 8-bit engine (Web Audio API). No asset
// files: the music and the swoosh/whop/clear SFX are synthesized live with
// oscillators + noise. One mute switch gates everything, defaults to muted, and
// is persisted. The AudioContext is created only on the first unmute (a user
// gesture), so there are no autoplay issues and nothing sounds until opt-in.
//
// The music is arranged as a short song, not a single loop: section A (the calm
// main theme) → B (uptempo) → C (medium) → back to A, cycling. SFX run through a
// convolution reverb send for a more cinematic feel.
import { useSyncExternalStore, useCallback } from 'react';
import { DROPBLOCK_MUTED as MUTE_KEY } from './storageKeys';

// Read/write the mute flag defensively: some embedded WebViews (notably iOS
// `loadHTMLString` with an opaque origin) throw on *any* localStorage access, and
// an unguarded read here at module load would crash the whole bundle.
function readMuted() {
  try { return (localStorage.getItem(MUTE_KEY) ?? 'true') === 'true'; } catch { return true; }
}
function writeMuted(m) {
  try { localStorage.setItem(MUTE_KEY, String(m)); } catch { /* storage unavailable */ }
}

let _muted = readMuted(); // default muted
const _subs = new Set();
const _emit = () => { for (const f of _subs) f(); };

let ctx = null;
let musicGain = null;
let sfxGain = null;
let reverb = null;
let reverbGain = null;
let schedTimer = null;
let nextNoteTime = 0;
let sectionIdx = 0;
let stepInSection = 0;
let playing = false;
let lastSwoosh = 0;
let wakaUp = false; // alternates the Pac-Man chomp between two pitches (waka-waka)
let noiseBuf = null;
// Tempo multiplier on the music clock (1 = normal). The Pac-Man frenzy bumps this
// up so the song races while the player chomps, then drops it back to 1.
let tempoMul = 1;

const hz = (midi) => 440 * Math.pow(2, (midi - 69) / 12);
const STEPS = 32;

// ── Three sections in C major (bright). Each is 32 sixteenth-notes. Plays as a
// song: A (calm main theme) → medium bridge → uptempo lift → back to A, cycling.
const SECTIONS = [
  { // A — calm main theme (C G Am F)
    bpm: 112, perc: 'a',
    lead: [72, null, 79, 76, 77, null, 76, 74, 76, null, 72, 76, 79, null, 76, 72,
           74, null, 77, 76, 74, null, 72, 71, 72, null, 76, 79, 84, null, 79, 76],
    bass: [48, 48, 48, 48, 43, 43, 43, 43, 45, 45, 45, 45, 41, 41, 41, 41,
           48, 48, 48, 48, 43, 43, 43, 43, 45, 45, 45, 45, 41, 41, 41, 41],
  },
  { // medium bridge, spaced and melodic (F C G C)
    bpm: 120, perc: 'c',
    lead: [76, null, null, 79, 84, null, 79, null, 81, null, 79, null, 77, null, 76, null,
           79, null, null, 76, 77, null, 76, null, 72, null, 74, null, 72, null, null, null],
    bass: [41, 41, 41, 41, 48, 48, 48, 48, 43, 43, 43, 43, 48, 48, 48, 48,
           41, 41, 41, 41, 48, 48, 48, 48, 43, 43, 43, 43, 48, 48, 48, 48],
  },
  { // uptempo lift — higher register, eighth-note motion so it lifts without racing
    bpm: 112, perc: 'b',
    lead: [84, null, 83, null, 88, null, 84, null, 83, null, 79, null, 84, null, 83, null,
           81, null, 79, null, 84, null, 81, null, 79, null, 77, null, 79, null, 76, null],
    bass: [48, 48, 48, 48, 43, 43, 43, 43, 41, 41, 41, 41, 48, 48, 48, 48,
           48, 48, 48, 48, 43, 43, 43, 43, 41, 41, 41, 41, 48, 48, 48, 48],
  },
];

function makeReverbIR(seconds = 1.8, decay = 2.6) {
  const len = Math.floor(ctx.sampleRate * seconds);
  const buf = ctx.createBuffer(2, len, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch);
    for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, decay);
  }
  return buf;
}

function ensureCtx() {
  if (ctx) return ctx;
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return null;
  ctx = new AC();
  musicGain = ctx.createGain(); musicGain.gain.value = 0.5; musicGain.connect(ctx.destination);
  sfxGain = ctx.createGain(); sfxGain.gain.value = 0.6; sfxGain.connect(ctx.destination);
  reverb = ctx.createConvolver(); reverb.buffer = makeReverbIR();
  reverbGain = ctx.createGain(); reverbGain.gain.value = 0.45;
  reverb.connect(reverbGain); reverbGain.connect(ctx.destination);
  return ctx;
}

function noise() {
  if (noiseBuf) return noiseBuf;
  const len = Math.floor(ctx.sampleRate * 0.5);
  noiseBuf = ctx.createBuffer(1, len, ctx.sampleRate);
  const d = noiseBuf.getChannelData(0);
  for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
  return noiseBuf;
}

// Route an SFX node to both the dry bus and the reverb send (cinematic tail).
function out(node, wet = 1) {
  node.connect(sfxGain);
  if (wet > 0) {
    const w = ctx.createGain(); w.gain.value = wet;
    node.connect(w); w.connect(reverb);
  }
}

function blip(dest, type, freq, t, dur, vol) {
  const o = ctx.createOscillator();
  o.type = type;
  o.frequency.setValueAtTime(freq, t);
  const g = ctx.createGain();
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(vol, t + 0.008);
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  o.connect(g); g.connect(dest);
  o.start(t); o.stop(t + dur + 0.02);
}

function hat(t, vol) {
  const s = ctx.createBufferSource(); s.buffer = noise();
  const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 7000;
  const g = ctx.createGain();
  g.gain.setValueAtTime(vol, t);
  g.gain.exponentialRampToValueAtTime(0.0001, t + 0.04);
  s.connect(hp); hp.connect(g); g.connect(musicGain); s.start(t); s.stop(t + 0.05);
}

function scheduleStep(sec, i, t, stepDur) {
  if (sec.lead[i] != null) blip(musicGain, 'square', hz(sec.lead[i]), t, stepDur * 0.9, 0.12);
  // Bass in its own (non-sub) octave — no octave-down, so it stays clean.
  if (i % 2 === 0) blip(musicGain, 'triangle', hz(sec.bass[i]), t, stepDur * 1.8, 0.15);

  // Light hat rhythm only — no kick (it read as a "thonk").
  if (sec.perc === 'a') {
    if (i % 4 === 2) hat(t, 0.07); else if (i % 2 === 1) hat(t, 0.03);
  } else if (sec.perc === 'b') {
    if (i % 2 === 1) hat(t, 0.06); else hat(t, 0.022);
  } else { // c — sparse
    if (i % 4 === 0) hat(t, 0.05);
  }
}

function scheduler() {
  if (!ctx) return;
  while (nextNoteTime < ctx.currentTime + 0.12) {
    const sec = SECTIONS[sectionIdx];
    const stepDur = 60 / sec.bpm / 4 / tempoMul;
    scheduleStep(sec, stepInSection, nextNoteTime, stepDur);
    nextNoteTime += stepDur;
    stepInSection += 1;
    if (stepInSection >= STEPS) {
      stepInSection = 0;
      sectionIdx = (sectionIdx + 1) % SECTIONS.length; // A → B → C → A …
    }
  }
}

export function startMusic() {
  if (_muted || !ensureCtx() || playing) return;
  if (ctx.state === 'suspended') ctx.resume();
  playing = true;
  sectionIdx = 0;
  stepInSection = 0;
  nextNoteTime = ctx.currentTime + 0.05;
  schedTimer = setInterval(scheduler, 25);
  scheduler();
}

export function stopMusic() {
  playing = false;
  if (schedTimer) { clearInterval(schedTimer); schedTimer = null; }
}

// Set the music tempo multiplier (1 = normal, >1 = faster). Used to race the song
// during a Pac-Man frenzy. Takes effect on the next scheduled step.
export function setMusicTempo(mul) { tempoMul = mul > 0 ? mul : 1; }

// One-shot, cinematic SFX. `swoosh` = move/rotate, `whop` = lock/hard-drop,
// `clear` = 1–3 line clear, `quad` = four-line clear celebration, `bomb` =
// the bomb's electric beam-weapon detonation, `pacstart` = Pac-Man frenzy begins,
// `chomp` = a single Pac-Man bite (alternating waka-waka).
export function sfx(name, vol = 1) {
  if (_muted || !ensureCtx()) return;
  if (ctx.state === 'suspended') ctx.resume();
  const t = ctx.currentTime;

  if (name === 'swoosh') {
    if (t - lastSwoosh < 0.05) return; // throttle rapid auto-repeat
    lastSwoosh = t;
    // Airy filtered-noise whoosh: sweep up then settle, with a reverb tail.
    const s = ctx.createBufferSource(); s.buffer = noise();
    const bp = ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.Q.value = 1.2;
    bp.frequency.setValueAtTime(500, t);
    bp.frequency.exponentialRampToValueAtTime(3200, t + 0.12);
    bp.frequency.exponentialRampToValueAtTime(900, t + 0.26);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.11 * vol, t + 0.04);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.28);
    s.connect(bp); bp.connect(g); out(g, 0.5);
    s.start(t); s.stop(t + 0.3);
  } else if (name === 'whop') {
    // Cinematic impact: deep sub + body thump + filtered transient, reverb tail.
    const sub = ctx.createOscillator(); sub.type = 'sine';
    sub.frequency.setValueAtTime(75, t);
    sub.frequency.exponentialRampToValueAtTime(38, t + 0.25);
    const sg = ctx.createGain();
    sg.gain.setValueAtTime(0.0001, t);
    sg.gain.exponentialRampToValueAtTime(0.42, t + 0.008);
    sg.gain.exponentialRampToValueAtTime(0.0001, t + 0.3);
    sub.connect(sg); out(sg, 0.6); sub.start(t); sub.stop(t + 0.32);

    const body = ctx.createOscillator(); body.type = 'triangle';
    body.frequency.setValueAtTime(200, t);
    body.frequency.exponentialRampToValueAtTime(55, t + 0.16);
    const bg = ctx.createGain();
    bg.gain.setValueAtTime(0.0001, t);
    bg.gain.exponentialRampToValueAtTime(0.3, t + 0.006);
    bg.gain.exponentialRampToValueAtTime(0.0001, t + 0.2);
    body.connect(bg); out(bg, 0.5); body.start(t); body.stop(t + 0.22);

    const s = ctx.createBufferSource(); s.buffer = noise();
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1400;
    const ng = ctx.createGain();
    ng.gain.setValueAtTime(0.22, t);
    ng.gain.exponentialRampToValueAtTime(0.0001, t + 0.06);
    s.connect(lp); lp.connect(ng); out(ng, 0.4); s.start(t); s.stop(t + 0.08);
  } else if (name === 'clear') {
    // Rising shimmer chord with a long reverb tail.
    [0, 4, 7, 12, 16].forEach((semi, i) => {
      const o = ctx.createOscillator(); o.type = 'square';
      const tt = t + i * 0.06;
      o.frequency.setValueAtTime(hz(72 + semi), tt);
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, tt);
      g.gain.exponentialRampToValueAtTime(0.13, tt + 0.01);
      g.gain.exponentialRampToValueAtTime(0.0001, tt + 0.35);
      o.connect(g); out(g, 0.8); o.start(tt); o.stop(tt + 0.4);
    });
  } else if (name === 'quad') {
    // Four-line clear celebration: a bright "ta-da-daaa" fanfare. Two layered
    // voices per note (square lead + triangle body), last note held and accented.

    // ── "Ta-da-daaa!" — rising triad fanfare, last note held and accented.
    const fanfare = [
      { semi: 67, at: 0.00, dur: 0.13, vol: 0.16 }, // G  — ta
      { semi: 72, at: 0.13, dur: 0.13, vol: 0.18 }, // C  — da
      { semi: 76, at: 0.26, dur: 0.40, vol: 0.22 }, // E  — daaa (held)
    ];
    for (const n of fanfare) {
      const tt = t + n.at;
      const lead = ctx.createOscillator(); lead.type = 'square';
      lead.frequency.setValueAtTime(hz(n.semi), tt);
      const lg = ctx.createGain();
      lg.gain.setValueAtTime(0.0001, tt);
      lg.gain.exponentialRampToValueAtTime(n.vol, tt + 0.01);
      lg.gain.exponentialRampToValueAtTime(0.0001, tt + n.dur);
      lead.connect(lg); out(lg, 0.7); lead.start(tt); lead.stop(tt + n.dur + 0.05);

      const body = ctx.createOscillator(); body.type = 'triangle';
      body.frequency.setValueAtTime(hz(n.semi - 12), tt);
      const bg = ctx.createGain();
      bg.gain.setValueAtTime(0.0001, tt);
      bg.gain.exponentialRampToValueAtTime(n.vol * 0.8, tt + 0.01);
      bg.gain.exponentialRampToValueAtTime(0.0001, tt + n.dur);
      body.connect(bg); out(bg, 0.6); body.start(tt); body.stop(tt + n.dur + 0.05);
    }
  } else if (name === 'bomb') {
    // Electric beam-weapon vaporize: a bright noise whoosh fanning out, a buzzy
    // descending zap (the discharge), a sub-boom impact, and a spark crackle.

    // 1. Whoosh — band-passed noise sweeping up then settling.
    const wh = ctx.createBufferSource(); wh.buffer = noise(); wh.loop = true;
    const whbp = ctx.createBiquadFilter(); whbp.type = 'bandpass'; whbp.Q.value = 0.8;
    whbp.frequency.setValueAtTime(400, t);
    whbp.frequency.exponentialRampToValueAtTime(5200, t + 0.16);
    whbp.frequency.exponentialRampToValueAtTime(700, t + 0.4);
    const whg = ctx.createGain();
    whg.gain.setValueAtTime(0.0001, t);
    whg.gain.exponentialRampToValueAtTime(0.18 * vol, t + 0.05);
    whg.gain.exponentialRampToValueAtTime(0.0001, t + 0.42);
    wh.connect(whbp); whbp.connect(whg); out(whg, 0.6); wh.start(t); wh.stop(t + 0.45);

    // 2. Buzzy descending zap — the electric discharge.
    const zap = ctx.createOscillator(); zap.type = 'sawtooth';
    zap.frequency.setValueAtTime(1300, t);
    zap.frequency.exponentialRampToValueAtTime(80, t + 0.28);
    const zlp = ctx.createBiquadFilter(); zlp.type = 'lowpass';
    zlp.frequency.setValueAtTime(4200, t);
    zlp.frequency.exponentialRampToValueAtTime(500, t + 0.28);
    const zg = ctx.createGain();
    zg.gain.setValueAtTime(0.0001, t);
    zg.gain.exponentialRampToValueAtTime(0.16 * vol, t + 0.01);
    zg.gain.exponentialRampToValueAtTime(0.0001, t + 0.3);
    zap.connect(zlp); zlp.connect(zg); out(zg, 0.5); zap.start(t); zap.stop(t + 0.32);

    // 3. Sub-boom impact.
    const sub = ctx.createOscillator(); sub.type = 'sine';
    sub.frequency.setValueAtTime(120, t);
    sub.frequency.exponentialRampToValueAtTime(40, t + 0.3);
    const sg = ctx.createGain();
    sg.gain.setValueAtTime(0.0001, t);
    sg.gain.exponentialRampToValueAtTime(0.4 * vol, t + 0.012);
    sg.gain.exponentialRampToValueAtTime(0.0001, t + 0.34);
    sub.connect(sg); out(sg, 0.6); sub.start(t); sub.stop(t + 0.36);

    // 4. Spark crackle — a few quick high-passed noise bursts.
    for (let i = 0; i < 5; i++) {
      const tt = t + 0.02 + i * 0.035;
      const sp = ctx.createBufferSource(); sp.buffer = noise();
      const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 5000;
      const spg = ctx.createGain();
      spg.gain.setValueAtTime(0.08 * vol, tt);
      spg.gain.exponentialRampToValueAtTime(0.0001, tt + 0.05);
      sp.connect(hp); hp.connect(spg); out(spg, 0.5); sp.start(tt); sp.stop(tt + 0.06);
    }
  } else if (name === 'gameover') {
    // Top-out: a cinematic "you lost" sting. A deep impact boom punctuates the
    // moment, a dramatic downward noise sweep falls underneath, a sad descending
    // C-minor knell plays the melody, and a sustained low C-minor "doom" chord
    // swells in and rings out on a long reverb tail. The gloomy mirror of `quad`.

    // ── 1. Impact boom — a deep cinematic thud on the downbeat.
    const boom = ctx.createOscillator(); boom.type = 'sine';
    boom.frequency.setValueAtTime(90, t);
    boom.frequency.exponentialRampToValueAtTime(28, t + 0.5);
    const boomG = ctx.createGain();
    boomG.gain.setValueAtTime(0.0001, t);
    boomG.gain.exponentialRampToValueAtTime(0.5, t + 0.012);
    boomG.gain.exponentialRampToValueAtTime(0.0001, t + 0.6);
    boom.connect(boomG); out(boomG, 0.7); boom.start(t); boom.stop(t + 0.64);

    const thud = ctx.createBufferSource(); thud.buffer = noise();
    const thlp = ctx.createBiquadFilter(); thlp.type = 'lowpass'; thlp.frequency.value = 900;
    const thG = ctx.createGain();
    thG.gain.setValueAtTime(0.28, t);
    thG.gain.exponentialRampToValueAtTime(0.0001, t + 0.12);
    thud.connect(thlp); thlp.connect(thG); out(thG, 0.5); thud.start(t); thud.stop(t + 0.14);

    // ── 2. Downward dramatic sweep — a falling filtered-noise "descent".
    const sweep = ctx.createBufferSource(); sweep.buffer = noise(); sweep.loop = true;
    const swbp = ctx.createBiquadFilter(); swbp.type = 'bandpass'; swbp.Q.value = 2.5;
    swbp.frequency.setValueAtTime(2600, t);
    swbp.frequency.exponentialRampToValueAtTime(180, t + 1.1);
    const swG = ctx.createGain();
    swG.gain.setValueAtTime(0.0001, t);
    swG.gain.exponentialRampToValueAtTime(0.09, t + 0.15);
    swG.gain.exponentialRampToValueAtTime(0.0001, t + 1.1);
    sweep.connect(swbp); swbp.connect(swG); out(swG, 0.9); sweep.start(t); sweep.stop(t + 1.15);

    // ── 3. Descending minor knell — the melody (G → Eb → C → low C).
    const knell = [
      { semi: 67, at: 0.10, dur: 0.26, vol: 0.16 }, // G  — wo
      { semi: 63, at: 0.32, dur: 0.26, vol: 0.16 }, // Eb — woo
      { semi: 60, at: 0.54, dur: 0.30, vol: 0.17 }, // C  — woom
    ];
    for (const n of knell) {
      const tt = t + n.at;
      // Sawtooth lead with a downward pitch droop for a "deflating" feel.
      const lead = ctx.createOscillator(); lead.type = 'sawtooth';
      lead.frequency.setValueAtTime(hz(n.semi), tt);
      lead.frequency.exponentialRampToValueAtTime(hz(n.semi - 1), tt + n.dur);
      const lg = ctx.createGain();
      lg.gain.setValueAtTime(0.0001, tt);
      lg.gain.exponentialRampToValueAtTime(n.vol, tt + 0.02);
      lg.gain.exponentialRampToValueAtTime(0.0001, tt + n.dur);
      lead.connect(lg); out(lg, 0.85); lead.start(tt); lead.stop(tt + n.dur + 0.05);

      // Triangle sub-octave body for weight.
      const body = ctx.createOscillator(); body.type = 'triangle';
      body.frequency.setValueAtTime(hz(n.semi - 12), tt);
      const bg = ctx.createGain();
      bg.gain.setValueAtTime(0.0001, tt);
      bg.gain.exponentialRampToValueAtTime(n.vol * 0.7, tt + 0.02);
      bg.gain.exponentialRampToValueAtTime(0.0001, tt + n.dur);
      body.connect(bg); out(bg, 0.6); body.start(tt); body.stop(tt + n.dur + 0.05);
    }

    // ── 4. Sustained low C-minor "doom" chord (C Eb G) — swells in under the
    // final note and rings out long on the reverb send for a cinematic tail.
    const chordAt = t + 0.60;
    [36, 39, 43].forEach((semi) => {
      const o = ctx.createOscillator(); o.type = 'sawtooth';
      o.frequency.setValueAtTime(hz(semi), chordAt);
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, chordAt);
      g.gain.exponentialRampToValueAtTime(0.1, chordAt + 0.25);
      g.gain.exponentialRampToValueAtTime(0.0001, chordAt + 2.0);
      const lp = ctx.createBiquadFilter(); lp.type = 'lowpass';
      lp.frequency.setValueAtTime(1400, chordAt);
      lp.frequency.exponentialRampToValueAtTime(420, chordAt + 1.8);
      o.connect(lp); lp.connect(g); out(g, 1); o.start(chordAt); o.stop(chordAt + 2.1);
    });
  } else if (name === 'chomp') {
    // A single Pac-Man bite — the classic "waka". A short pitch-bent tone that
    // alternates direction each bite, with a tiny noise click for the "k".
    wakaUp = !wakaUp;
    const f0 = wakaUp ? 360 : 520;
    const f1 = wakaUp ? 600 : 300;
    const o = ctx.createOscillator(); o.type = 'square';
    o.frequency.setValueAtTime(f0, t);
    o.frequency.exponentialRampToValueAtTime(f1, t + 0.07);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1700;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.14 * vol, t + 0.006);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.09);
    o.connect(lp); lp.connect(g); out(g, 0.25); o.start(t); o.stop(t + 0.1);

    const s = ctx.createBufferSource(); s.buffer = noise();
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 2500;
    const ng = ctx.createGain();
    ng.gain.setValueAtTime(0.05 * vol, t);
    ng.gain.exponentialRampToValueAtTime(0.0001, t + 0.03);
    s.connect(hp); hp.connect(ng); ng.connect(sfxGain); s.start(t); s.stop(t + 0.04);
  } else if (name === 'pacstart') {
    // Frenzy begins — a bright rising power-up arpeggio (C E G C), reverb tail.
    [60, 64, 67, 72].forEach((semi, i) => {
      const tt = t + i * 0.07;
      const o = ctx.createOscillator(); o.type = 'square';
      o.frequency.setValueAtTime(hz(semi), tt);
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, tt);
      g.gain.exponentialRampToValueAtTime(0.15 * vol, tt + 0.01);
      g.gain.exponentialRampToValueAtTime(0.0001, tt + 0.18);
      o.connect(g); out(g, 0.6); o.start(tt); o.stop(tt + 0.2);
    });
  }
}

export function getMuted() { return _muted; }

export function setMuted(m) {
  m = !!m;
  if (m === _muted) return;
  _muted = m;
  writeMuted(m);
  if (m) {
    stopMusic();
  } else {
    ensureCtx();
    if (ctx && ctx.state === 'suspended') ctx.resume();
  }
  _emit();
}

function subscribe(cb) { _subs.add(cb); return () => _subs.delete(cb); }

export function useDropBlockMuted() {
  const muted = useSyncExternalStore(subscribe, getMuted);
  return {
    muted,
    toggle: useCallback(() => setMuted(!getMuted()), []),
  };
}
