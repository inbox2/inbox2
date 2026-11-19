// Subject prefix stripping for display — mirrors SubjectNormalizer in
// api/app/services/subject_normalizer.rb (keep in sync).

// Latin-script reply/forward prefixes (case-insensitive)
const LATIN_PREFIXES = [
  're', 'fw', 'fwd',           // English
  'sv',                         // Swedish/Norwegian/Danish
  'aw', 'wg',                  // German
  'tr', 'rép',                 // French
  'vs',                         // Finnish
  'ref', 'rif',                // Italian
  'ynt',                        // Turkish
  'odp',                        // Polish
  'atb',                        // Welsh
  'enc', 'res',                // Portuguese/Catalan
  'doorst',                     // Dutch
  'va', 'vá',                  // Hungarian
  'fs', 'vb',                  // Icelandic
  'rv',                         // Norwegian Bokmål
  'pd',                         // Czech/Slovak
  'rep', 'beantw', 'antw',    // Afrikaans/Dutch
  'svar',                       // Scandinavian
]

// Non-Latin prefixes
const NON_LATIN_PREFIXES = [
  '回复', '转发',               // Chinese Simplified
  '回覆', '轉寄',               // Chinese Traditional
  '답장', '전달',               // Korean
  '返信', '転送',               // Japanese
  'השב', 'הועבר',              // Hebrew
  'رد', 'إعادة توجيه',         // Arabic
  'उत्तर', 'अग्रेषित',           // Hindi
  'ΑΠ', 'ΠΡΘ',                 // Greek
  'НА', 'ОТВ', 'ПЕР',         // Russian/Bulgarian
]

const LATIN_GROUP = LATIN_PREFIXES.map(p => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')
const NON_LATIN_GROUP = NON_LATIN_PREFIXES.map(p => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')
const PREFIX_RE = new RegExp(
  `^\\s*(?:(?:${LATIN_GROUP})(?:\\[\\d+\\])?:\\s*|(?:${NON_LATIN_GROUP})(?:\\[\\d+\\])?:?\\s*)`,
  'i',
)

/**
 * Strip reply/forward prefixes from a subject for display.
 * "Re: Fwd: Re: Meeting notes" → "Meeting notes"
 */
export function stripSubjectPrefixes(subject) {
  if (!subject) return subject
  let s = subject.trim()
  let prev
  do {
    prev = s
    s = s.replace(PREFIX_RE, '')
  } while (s !== prev)
  return s || subject
}
