// Render plain text with bare URLs turned into clickable links. Used for
// user-authored free text (event descriptions/notes, locations) where we want
// links to open without trusting/rendering arbitrary HTML. Trailing sentence
// punctuation is left outside the link so "see https://x.com." doesn't capture
// the period.
const URL_RE = /(https?:\/\/[^\s<]+[^\s<.,:;!?"')\]}])/gi;

export default function Linkify({ text, className }) {
  if (text == null || text === '') return null;
  // split() with a capturing group keeps the URLs as alternating array slots.
  const parts = String(text).split(URL_RE);
  return (
    <>
      {parts.map((part, i) =>
        /^https?:\/\//i.test(part) ? (
          <a key={i} href={part} target="_blank" rel="noopener noreferrer" className={className}>
            {part}
          </a>
        ) : (
          part
        )
      )}
    </>
  );
}
