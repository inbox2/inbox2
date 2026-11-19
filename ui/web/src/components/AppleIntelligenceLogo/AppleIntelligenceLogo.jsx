// Apple Intelligence brand mark — used by the On-device AI settings panel.
export default function AppleIntelligenceLogo({ size = 24 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <defs>
        <linearGradient id="ai-grad" x1="0" y1="0" x2="32" y2="32" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stopColor="#FF6CAB" />
          <stop offset="33%" stopColor="#7366FF" />
          <stop offset="66%" stopColor="#00C2FF" />
          <stop offset="100%" stopColor="#5BF" />
        </linearGradient>
      </defs>
      <rect width="32" height="32" rx="7" fill="#1C1C1E" />
      <circle cx="16" cy="14" r="7" stroke="url(#ai-grad)" strokeWidth="1.5" fill="none" />
      <circle cx="16" cy="14" r="2" fill="url(#ai-grad)" />
      <path d="M11 24h10" stroke="url(#ai-grad)" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}
