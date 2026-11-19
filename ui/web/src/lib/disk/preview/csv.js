// RFC 4180 CSV (and TSV) to rows, for the CSV quick view. Quoted fields may hold
// the delimiter, doubled quotes and newlines. Stops after maxRows rows.
export function parseCsv(text, { delimiter, maxRows = Infinity } = {}) {
  const d = delimiter || guessDelimiter(text)
  const rows = []
  let row = []
  let field = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++ }
      else if (c === '"') quoted = false
      else field += c
    } else if (c === '"' && field === '') quoted = true
    else if (c === d) { row.push(field); field = '' }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++
      row.push(field)
      rows.push(row)
      row = []
      field = ''
      if (rows.length >= maxRows) return { rows, truncated: i < text.length - 1 }
    } else field += c
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row) }
  return { rows, truncated: false }
}

/** Tab when the first line has more tabs than commas or semicolons, else the most common of those. */
export function guessDelimiter(text) {
  const line = text.slice(0, text.search(/\r?\n/) >>> 0 || text.length)
  const count = (ch) => line.split(ch).length - 1
  return ['\t', ',', ';'].reduce((best, ch) => (count(ch) > count(best) ? ch : best), ',')
}
