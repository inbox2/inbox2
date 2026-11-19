import { Fragment } from "react";

/* Platform glyphs (ported from the previous site's OsBadges) + web/cli strokes. */

const APPLE =
  "M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701";
const WINDOWS =
  "M0 3.449L9.75 2.1v9.451H0m10.949-9.602L24 0v11.4H10.949M0 12.6h9.75v9.451L0 20.699m10.949-8.099H24V24l-13.051-1.801";
const ANDROID =
  "M18.4395 5.5586c-.675 1.1664-1.352 2.3318-2.0274 3.498-.0366-.0155-.0742-.0286-.1113-.043-1.8249-.6957-3.484-.8-4.42-.787-1.8551.0185-3.3544.4643-4.2597.8203-.084-.1494-1.7526-3.021-2.0215-3.4864a1.1451 1.1451 0 0 0-.1406-.1914c-.3312-.364-.9054-.4859-1.379-.203-.475.282-.7136.9361-.3886 1.5019 1.9466 3.3696-.0966-.2158 1.9473 3.3593.0172.031-.4946.2642-1.3926 1.0177C2.8987 12.176.452 14.772 0 18.9902h24c-.119-1.1108-.3686-2.099-.7461-3.0683-.7438-1.9118-1.8435-3.2928-2.7402-4.1836a12.1048 12.1048 0 0 0-2.1309-1.6875c.6594-1.122 1.312-2.2559 1.9649-3.3848.2077-.3615.1886-.7956-.0079-1.1191a1.1001 1.1001 0 0 0-.8515-.5332c-.5225-.0536-.9392.3128-1.0488.5449zm-.0391 8.461c.3944.5926.324 1.3306-.1563 1.6503-.4799.3197-1.188.0985-1.582-.4941-.3944-.5927-.324-1.3307.1563-1.6504.4727-.315 1.1812-.1086 1.582.4941zM7.207 13.5273c.4803.3197.5506 1.0577.1563 1.6504-.394.5926-1.1038.8138-1.584.4941-.48-.3197-.5503-1.0577-.1563-1.6504.4008-.6021 1.1087-.8106 1.584-.4941z";
const TUX =
  "M12.504 0c-.155 0-.315.008-.48.021-4.226.333-3.105 4.807-3.17 6.298-.076 1.092-.3 1.953-1.05 3.02-.885 1.051-2.127 2.75-2.716 4.521-.278.832-.41 1.684-.287 2.489a.424.424 0 00-.11.135c-.26.268-.45.6-.663.839-.199.199-.485.267-.797.4-.313.136-.658.269-.864.68-.09.189-.136.394-.132.602 0 .199.027.4.055.536.058.399.116.728.04.97-.249.68-.28 1.145-.106 1.484.174.334.535.47.94.601.81.2 1.91.135 2.774.6.926.466 1.866.67 2.616.47.526-.116.97-.464 1.208-.946.587-.003 1.23-.269 2.26-.334.699-.058 1.574.267 2.577.2.025.134.063.198.114.333l.003.003c.391.778 1.113 1.132 1.884 1.071.771-.06 1.592-.536 2.257-1.306.631-.765 1.683-1.084 2.378-1.503.348-.199.629-.469.649-.853.023-.4-.2-.811-.714-1.376v-.097l-.003-.003c-.17-.2-.25-.535-.338-.926-.085-.401-.182-.786-.492-1.046h-.003c-.059-.054-.123-.067-.188-.135a.357.357 0 00-.19-.064c.431-1.278.264-2.55-.173-3.694-.533-1.41-1.465-2.638-2.175-3.483-.796-1.005-1.576-1.957-1.56-3.368.026-2.152.236-6.133-3.544-6.139z";

const FILLS = { macos: APPLE, ios: APPLE, windows: WINDOWS, android: ANDROID, linux: TUX };

export const PLATFORMS = [
  { id: "macos", name: "macOS", sub: "Apple silicon", href: "https://mail.inbox2.com/console" },
  { id: "windows", name: "Windows", sub: "10 and 11", href: "https://mail.inbox2.com/console" },
  { id: "linux", name: "Linux", sub: ".deb", href: "https://mail.inbox2.com/console" },
  // No store listings yet, so both point at the console like the desktop
  // builds do. Swap in the real URLs (Apple needs /app/id<number>) on launch.
  { id: "ios", name: "iOS", sub: "iPhone + iPad", href: "https://mail.inbox2.com/console" },
  { id: "android", name: "Android", sub: "Phones + tablets", href: "https://mail.inbox2.com/console" },
];

/* Full-colour versions for the big download tiles. Apple wears the 1977 rainbow;
   Tux keeps a currentColor body (so he reads on both light and dark tiles) with
   his beak and feet in orange. Windows and Android use their brand colours. */
const RAINBOW = [
  ["#61bb46", 0],
  ["#fdb827", 1],
  ["#f5821f", 2],
  ["#e03a3e", 3],
  ["#963d97", 4],
  ["#009ddc", 5],
];

function ColorGlyph({ id, size }) {
  if (id === "macos" || id === "ios") {
    return (
      <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true">
        <defs>
          <linearGradient id="os-apple" x1="0" y1="0" x2="0" y2="1">
            {RAINBOW.map(([c, i]) => (
              <Fragment key={c}>
                <stop offset={`${(i / 6) * 100}%`} stopColor={c} />
                <stop offset={`${((i + 1) / 6) * 100}%`} stopColor={c} />
              </Fragment>
            ))}
          </linearGradient>
        </defs>
        <path d={APPLE} fill="url(#os-apple)" />
      </svg>
    );
  }
  if (id === "windows") {
    return (
      <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true">
        <path d={WINDOWS} fill="#0078d4" />
      </svg>
    );
  }
  if (id === "android") {
    return (
      <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true">
        <path d={ANDROID} fill="#3ddc84" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true">
      <path d={TUX} fill="currentColor" />
      <ellipse cx="12" cy="5.6" rx="1.9" ry="1.2" fill="#f5b301" />
      <ellipse cx="6.3" cy="22.6" rx="2.4" ry="1.4" fill="#f5b301" transform="rotate(-18 6.3 22.6)" />
      <ellipse cx="17.6" cy="22.4" rx="2.4" ry="1.4" fill="#f5b301" transform="rotate(15 17.6 22.4)" />
    </svg>
  );
}

export function OsIcon({ id, size = 16, colored = false }) {
  if (colored && FILLS[id]) return <ColorGlyph id={id} size={size} />;
  if (id === "web") {
    return (
      <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
        <circle cx="12" cy="12" r="9" />
        <path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18" />
      </svg>
    );
  }
  if (id === "cli") {
    return (
      <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M4 6l6 6-6 6M12 18h8" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true">
      <path d={FILLS[id]} fill="currentColor" />
    </svg>
  );
}

export function DownloadArrow({ size = 16 }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 3v12M7 10l5 5 5-5M4 19h16" />
    </svg>
  );
}
