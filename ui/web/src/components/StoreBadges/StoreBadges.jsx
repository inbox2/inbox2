/* Platform glyphs for the console Apps page. Monochrome (currentColor) by
 * default; a parent that sets the --apple-N, --g-*, --w-* and --tux-* vars paints
 * them in their brand colours. */

// Monochrome (currentColor) at rest; the parent sets --apple-1…6
// to the classic six-stripe Apple rainbow, which this gradient reveals.
export function AppleMark({ size = 20, gradientId = 'appleG' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <defs>
        <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="var(--apple-1, currentColor)" />
          <stop offset="0.166" stopColor="var(--apple-1, currentColor)" />
          <stop offset="0.166" stopColor="var(--apple-2, currentColor)" />
          <stop offset="0.333" stopColor="var(--apple-2, currentColor)" />
          <stop offset="0.333" stopColor="var(--apple-3, currentColor)" />
          <stop offset="0.5" stopColor="var(--apple-3, currentColor)" />
          <stop offset="0.5" stopColor="var(--apple-4, currentColor)" />
          <stop offset="0.666" stopColor="var(--apple-4, currentColor)" />
          <stop offset="0.666" stopColor="var(--apple-5, currentColor)" />
          <stop offset="0.833" stopColor="var(--apple-5, currentColor)" />
          <stop offset="0.833" stopColor="var(--apple-6, currentColor)" />
          <stop offset="1" stopColor="var(--apple-6, currentColor)" />
        </linearGradient>
      </defs>
      <path fill={`url(#${gradientId})`} d="M17.05 12.04c-.03-2.6 2.12-3.84 2.22-3.9-1.21-1.78-3.09-2.02-3.76-2.05-1.6-.16-3.12.94-3.93.94-.81 0-2.06-.92-3.39-.9-1.74.03-3.35 1.02-4.25 2.58-1.81 3.13-.46 7.78 1.3 10.33.86 1.25 1.88 2.65 3.22 2.6 1.29-.05 1.78-.83 3.34-.83 1.56 0 2 .83 3.37.81 1.39-.03 2.27-1.27 3.12-2.53.98-1.45 1.39-2.85 1.41-2.92-.03-.01-2.7-1.04-2.73-4.11l-.001-.011zM14.6 4.6c.71-.86 1.19-2.06 1.06-3.25-1.02.04-2.26.68-3 1.54-.66.76-1.24 1.98-1.08 3.15 1.14.09 2.31-.58 3.02-1.44z" />
    </svg>
  );
}

export function PlayMark({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3.6 2.3C3.3 2.5 3.1 2.85 3.1 3.32v17.36c0 .47.2.82.5 1.02l9.55-9.7L3.6 2.3z" fill="var(--g-blue, currentColor)" />
      <path d="M16.95 8.55 13.15 12l3.8 3.45 4-2.3c.72-.42.72-1.48 0-1.9l-4-2.7z" fill="var(--g-yellow, currentColor)" />
      <path d="M3.6 21.7c.38.25.86.22 1.32-.05L16.95 15.45 13.15 12 3.6 21.7z" fill="var(--g-red, currentColor)" />
      <path d="M4.92 2.35c-.46-.27-.94-.3-1.32-.05L13.15 12l3.8-3.45L4.92 2.35z" fill="var(--g-green, currentColor)" />
    </svg>
  );
}

// Four tiles, each tinted to its classic Windows-flag colour on hover and
// monochrome (currentColor) at rest.
export function WindowsMark({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3 4.4 11.2 3.3v8.2H3V4.4z" fill="var(--w-red, currentColor)" />
      <path d="M12.3 3.15 21 2v9.5h-8.7V3.15z" fill="var(--w-green, currentColor)" />
      <path d="M3 12.5h8.2v8.2L3 19.6v-7.1z" fill="var(--w-blue, currentColor)" />
      <path d="M12.3 12.5H21V22l-8.7-1.15V12.5z" fill="var(--w-yellow, currentColor)" />
    </svg>
  );
}

// Simplified Tux glyph: monochrome body at rest, beak/feet tint on hover.
export function LinuxMark({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <ellipse cx="12" cy="13" rx="6" ry="8" fill="currentColor" />
      <ellipse cx="12" cy="15" rx="3.6" ry="5.4" fill="#fff" />
      <circle cx="9.8" cy="9" r="1" fill="#fff" />
      <circle cx="14.2" cy="9" r="1" fill="#fff" />
      <circle cx="9.95" cy="9.2" r="0.45" fill="#1a1a1a" />
      <circle cx="14.05" cy="9.2" r="0.45" fill="#1a1a1a" />
      <path d="M10.8 10.3h2.4l-1.2 1.7z" fill="var(--tux-beak, #f6a821)" />
      <path d="M8.6 20.6c-1 .6-2.4.2-2.2-.9.16-.85 1.5-1.2 2.5-1.4z" fill="var(--tux-foot, #f6a821)" />
      <path d="M15.4 20.6c1 .6 2.4.2 2.2-.9-.16-.85-1.5-1.2-2.5-1.4z" fill="var(--tux-foot, #f6a821)" />
    </svg>
  );
}
