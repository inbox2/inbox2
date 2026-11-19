import Icon from '../Icon';

/**
 * Tiny brand mark for a local CLI agent, keyed by adapter id. Inline SVG so it
 * scales with the surrounding text and needs no network request; falls back to a
 * generic chip glyph for unknown agents. Approximations of each tool's logo —
 * swap in exact brand art under public/agents/ later if needed.
 */
export default function AgentLogo({ adapterId, size = 14, className }) {
  const svg = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    className,
    'aria-hidden': true,
  };

  switch (adapterId) {
    // Anthropic / Claude — clay sunburst.
    case 'claude-code':
      return (
        <svg {...svg}>
          {Array.from({ length: 12 }, (_, i) => (
            <rect
              key={i}
              x="11.2"
              y="2.2"
              width="1.6"
              height="6.4"
              rx="0.8"
              fill="#D97757"
              transform={`rotate(${i * 30} 12 12)`}
            />
          ))}
        </svg>
      );

    // Google Gemini — four-point spark with a blue→violet gradient.
    case 'gemini':
      return (
        <svg {...svg}>
          <defs>
            <linearGradient id="agentGemini" x1="0" y1="0" x2="24" y2="24" gradientUnits="userSpaceOnUse">
              <stop offset="0" stopColor="#4796E3" />
              <stop offset="1" stopColor="#9177C7" />
            </linearGradient>
          </defs>
          <path
            d="M12 2 C12 7, 7 12, 2 12 C7 12, 12 17, 12 22 C12 17, 17 12, 22 12 C17 12, 12 7, 12 2 Z"
            fill="url(#agentGemini)"
          />
        </svg>
      );

    // OpenAI / Codex — six-lobe rosette nodding at the knot mark.
    case 'codex':
      return (
        <svg {...svg}>
          {[0, 60, 120].map((d) => (
            <ellipse
              key={d}
              cx="12"
              cy="12"
              rx="9"
              ry="3.4"
              fill="none"
              stroke="#10a37f"
              strokeWidth="1.6"
              transform={`rotate(${d} 12 12)`}
            />
          ))}
        </svg>
      );

    // OpenCode — terminal prompt mark.
    case 'opencode':
      return (
        <svg {...svg} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M6 8l4 4-4 4" />
          <path d="M13 16h5" />
        </svg>
      );

    default:
      return <Icon name="cpu" size={size} className={className} />;
  }
}
