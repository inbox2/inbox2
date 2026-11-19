import styles from './EspIcon.module.css';

/* Brand marks for the deliverability provider picker. Each ESP gets a distinct
 * brand-coloured chip so the dropdown reads at a glance (the `icon` keys mirror
 * the backend DeliveryProviders catalog). Custom ESPs are drawn SVG glyphs; the
 * inbox2 built-in uses the real /logo-mark.png brand mark. Sized via the `size` prop. */

// kind → { bg, label, inner(SVG children) }. Glyphs are drawn on a 24×24 grid.
// `builtin` is special-cased below to render the real inbox2 brand mark.
const GLYPHS = {
  ses: {
    bg: '#FF9900',
    label: 'Amazon SES',
    inner: <path d="M8 16h8.5a3 3 0 0 0 .3-6 4 4 0 0 0-7.7-1A3 3 0 0 0 8 16z" fill="#232F3E" />,
  },
  sendgrid: {
    bg: '#1A82E2',
    label: 'SendGrid',
    inner: <path d="M5 12.5L18 6l-3 12-3.2-3.4L16 8.5l-7.6 4.7z" fill="#fff" />,
  },
  mailgun: {
    bg: '#C02126',
    label: 'Mailgun',
    inner: <path d="M6 17V7h2.2l3.8 5 3.8-5H18v10h-2.4v-6l-3.6 4.7L8.4 11v6z" fill="#fff" />,
  },
  postmark: {
    bg: '#1F2A37',
    label: 'Postmark',
    inner: (
      <>
        <circle cx="12" cy="12" r="6.2" fill="#FFE03A" />
        <path d="M9.4 12.3l1.9 1.9 3.4-3.8" stroke="#1F2A37" strokeWidth="1.7" fill="none" strokeLinecap="round" strokeLinejoin="round" />
      </>
    ),
  },
  messy: {
    bg: '#7C3AED',
    label: 'Messy',
    inner: <path d="M12 4l2.1 5.3L19 11l-4.9 1.7L12 18l-2.1-5.3L5 11l4.9-1.7z" fill="#fff" />,
  },
  smtp: {
    bg: '#475569',
    label: 'Custom SMTP',
    inner: (
      <>
        <rect x="6" y="6.5" width="12" height="4.4" rx="1.2" fill="#fff" />
        <rect x="6" y="13.1" width="12" height="4.4" rx="1.2" fill="#fff" />
        <circle cx="8.4" cy="8.7" r="0.9" fill="#475569" />
        <circle cx="8.4" cy="15.3" r="0.9" fill="#475569" />
      </>
    ),
  },
};

export default function EspIcon({ icon, size = 22 }) {
  // The built-in inbox2 option uses the real brand logo, not a drawn glyph.
  if (icon === 'builtin') {
    return <img src="/logo-mark.png" alt="Inbox2" width={size} height={size} className={styles.logo} />;
  }
  const g = GLYPHS[icon] || GLYPHS.smtp;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" role="img" aria-label={g.label}>
      <rect x="0" y="0" width="24" height="24" rx="6" fill={g.bg} />
      {g.inner}
    </svg>
  );
}

export { GLYPHS };
