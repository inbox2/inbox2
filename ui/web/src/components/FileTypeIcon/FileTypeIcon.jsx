// Disk draws its own flat icon set, a deliberate exception to F3 (SF Symbols): the Disk plan picked it (disk.md, "File types to iconize").
import { fileType } from '../../lib/disk/fileTypes'
import { FILE_GLYPHS, EMBLEMS, SHARE_COLORS, FOLDER_COLOR } from './glyphs'
import styles from './FileTypeIcon.module.css'

const INK = [0x18, 0x22, 0x42]

// The folder's back tab: the colour mixed 70/30 with ink.
function backTab(hex) {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16))
  return `#${c.map((v, i) => Math.round(v * 0.7 + INK[i] * 0.3).toString(16).padStart(2, '0')).join('')}`
}

function Folder({ size, color, emblem, keyBadge }) {
  const glyph = EMBLEMS[emblem]?.[1]
  const [keyColor, keyGlyph] = FILE_GLYPHS.key
  return (
    <svg className={styles.icon} width={size} height={size * 0.875} viewBox="0 0 32 28" aria-hidden="true">
      <path d="M2 5.5A2.5 2.5 0 0 1 4.5 3h7.2a2 2 0 0 1 1.5.7L15 6h12.5A2.5 2.5 0 0 1 30 8.5v15a2.5 2.5 0 0 1-2.5 2.5h-23A2.5 2.5 0 0 1 2 23.5z" fill={backTab(color)} />
      <rect x="2" y="9" width="28" height="17" rx="2.5" fill={color} />
      <path d="M4.5 10.6h23" stroke="#fff" strokeOpacity=".35" />
      {glyph && <g transform="translate(10 11.8)" fill="#fff" stroke="#fff" strokeWidth="0">{glyph}</g>}
      {keyBadge && (
        <>
          <circle cx="25.5" cy="21.5" r="6" fill="#fff" stroke={color} strokeWidth="1" />
          <g transform="translate(21.2 17.2) scale(.62)" fill={keyColor} stroke={keyColor} strokeWidth="0">{keyGlyph}</g>
        </>
      )}
    </svg>
  )
}

function Paper({ size, icon }) {
  const [color, glyph] = FILE_GLYPHS[icon] || FILE_GLYPHS.file
  return (
    <svg className={styles.icon} width={size * 0.8125} height={size} viewBox="0 0 26 32" aria-hidden="true">
      <path d="M4.8 1.5h10.7L23 9v20a1.8 1.8 0 0 1-1.8 1.8H4.8A1.8 1.8 0 0 1 3 29V3.3a1.8 1.8 0 0 1 1.8-1.8z" fill="#fff" stroke="#182242" strokeOpacity=".26" strokeWidth="1" strokeLinejoin="round" />
      <path d="M15.5 1.5V7a2 2 0 0 0 2 2H23z" fill="#ece6d8" stroke="#182242" strokeOpacity=".26" strokeWidth="1" strokeLinejoin="round" />
      <g transform="translate(6 13.5)" fill={color} stroke={color} strokeWidth="0">{glyph}</g>
    </svg>
  )
}

function Drive({ size, drive }) {
  return (
    <svg className={styles.icon} width={size} height={size * (20 / 24)} viewBox="0 0 24 20" aria-hidden="true">
      <rect x="1.5" y="4" width="21" height="12" rx="2.5" fill="#fcfaf4" stroke="#182242" strokeOpacity=".4" strokeWidth="1.1" />
      <path d="M5 9h9" stroke="#182242" strokeOpacity=".4" strokeWidth="1.1" strokeLinecap="round" />
      <circle cx="18.5" cy="11.5" r="1.4" fill={drive === 'C' ? '#2e8f5b' : '#2f7ad6'} />
    </svg>
  )
}

/**
 * Disk icon for a node.
 *   kind    'file' | 'folder' | 'page' | 'share' | 'drive'
 *   name, mime  pick the file glyph (see lib/disk/fileTypes.js); `type` forces an icon key
 *   sealed, shared  folder emblems (sealed wins)
 *   keyBadge  a sealed folder drawn plain with a key badge bottom right (a sealed folder tile's body)
 *   emblem, color   share emblem key, and a colour key (SHARE_COLORS) or #rrggbb; colour defaults to the emblem's
 *   drive   'C', or a team's letter ('D', 'E', ...) for kind="drive"
 *   size    height of a file, width of a folder, in px
 */
export default function FileTypeIcon({ kind = 'file', name, mime, type, sealed, shared, keyBadge, emblem, color, drive, size = 32 }) {
  if (kind === 'drive') return <Drive size={size} drive={drive} />
  if (kind === 'share') {
    const key = color || EMBLEMS[emblem]?.[0]
    return <Folder size={size} color={SHARE_COLORS[key] || (/^#[0-9a-f]{6}$/i.test(key || '') ? key : FOLDER_COLOR)} emblem={emblem} />
  }
  if (kind === 'folder') {
    const e = keyBadge ? null : sealed ? 'sealed' : shared ? 'shared' : null
    return <Folder size={size} color={sealed ? SHARE_COLORS.green : FOLDER_COLOR} emblem={e} keyBadge={keyBadge} />
  }
  if (kind === 'page') return <Paper size={size} icon="page" />
  return <Paper size={size} icon={type || fileType({ name, mime }).icon} />
}
