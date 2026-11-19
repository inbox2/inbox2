/* Line-art glyphs for the point lists. 24-grid, stroke only, so they inherit
   the text colour on both the light and the dark sections. */
export const GLYPHS = {
  inbox: "M3 13l2-8h14l2 8v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1zM3 13h5l1.5 2.5h5L16 13h5",
  boards: "M4 4h4v15H4zM10 4h4v10h-4zM16 4h4v12h-4z",
  keyboard: "M3 6h18v12H3zM7 10h.01M11 10h.01M15 10h.01M8 14h8",
  update: "M12 3v10m0 0l-3.5-3.5M12 13l3.5-3.5M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3",
  globe: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M3.5 9h17M3.5 15h17M12 3c2.5 2.6 2.5 15.4 0 18M12 3c-2.5 2.6-2.5 15.4 0 18",
  shield: "M12 3l7 3v6c0 4.2-3 7.2-7 9-4-1.8-7-4.8-7-9V6zM9 12l2 2 4-4",
  calendar: "M4 6h16v14H4zM4 10h16M9 3v4M15 3v4",
  console: "M4 5h16v14H4zM8 10l2.5 2.5L8 15M13.5 15H17",
  waveform: "M3 12h2M7.5 7.5v9M12 4.5v15M16.5 8.5v7M21 11h-2",
  lock: "M6 10.5h12v9H6zM9 10.5V7a3 3 0 0 1 6 0v3.5M12 14v2.5",
  bell: "M6 16V11a6 6 0 1 1 12 0v5l1.5 2.5h-15zM10 21h4",
};

export default function Glyph({ id }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={GLYPHS[id]} />
    </svg>
  );
}
