import useBrand from '../../hooks/useBrand';
import { initials } from '../../lib/lore';
import styles from './Lore.module.css';

// Steady tint per name, so "Moller" is always the same initials tile.
const TINTS = 8;
function tint(name) {
  let h = 0;
  for (const ch of String(name || '')) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return styles[`tint${h % TINTS}`];
}

/**
 * The little picture beside an organization or person in Lore: the domain's
 * own logo (useBrand) when it has one, else an initials tile (org: square,
 * person: round). `size`: 'sm' (16px, mentions), 'md' (22px), 'lg' (page icon).
 */
export default function EntityIcon({ domain, name, kind = 'org', size = 'sm' }) {
  const brand = useBrand(kind === 'org' ? domain : null);
  const cls = `${styles.entityIcon} ${styles[`icon_${size}`]}`;
  if (brand?.icon) return <img className={`${cls} ${styles.entityLogo}`} src={brand.icon} alt="" />;
  return (
    <span className={`${cls} ${kind === 'person' ? styles.entityRound : ''} ${tint(name)}`} aria-hidden="true">
      {initials(name)}
    </span>
  );
}

/** "@ALFAHIM" style inline mention: icon + underlined name. */
export function Mention({ domain, name, kind = 'org', onClick }) {
  const body = (
    <>
      <EntityIcon domain={domain} name={name} kind={kind} />
      <span>{name}</span>
    </>
  );
  if (!onClick) return <span className={styles.mention}>{body}</span>;
  return (
    <button type="button" className={`${styles.mention} ${styles.mentionButton}`} onClick={onClick}>
      {body}
    </button>
  );
}
