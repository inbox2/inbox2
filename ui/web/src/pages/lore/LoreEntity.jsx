import { useEffect, useRef } from 'react';
import Icon from '../../components/Icon';
import EntityIcon, { Mention } from '../../components/Lore/EntityIcon';
import { EntityActions, FactActions } from '../../components/Lore/EntityEditor';
import LoreItem from '../../components/Lore/LoreItem';
import { LORE_PATH, entityPath } from '../../components/Lore/openItem';
import useBrand from '../../hooks/useBrand';
import useLore, { LORE_SCOPE } from '../../hooks/useLore';
import useLoreFacts from '../../hooks/useLoreFacts';
import { BUCKET_TAG, LORE_BUCKET, LORE_KIND_LABEL, ageLabel, domainLabel, entitiesFrom } from '../../lib/lore';
import styles from '../../components/Lore/Lore.module.css';

const RECENT_DONE = 8;

const lastLabel = (at) => {
  if (!at) return '—';
  const age = ageLabel(at);
  return age === 'today' || age === 'yesterday' ? age : `${age} ago`;
};

/**
 * An organization (kind 'org', id = domain) or a person (kind 'person', id =
 * address) as a Lore page. The ontology's deterministic half (docs/plans/lore.md
 * §4): everything here is derived from the mail itself — the domain's own logo
 * and cover (§4b), the people writing from it, what is still open with them,
 * and what was recently ticked off.
 */
export default function LoreEntity({ ctx, kind, id }) {
  const { lore, open, toEntity, navigate } = ctx;
  const isOrg = kind === 'org';
  const brand = useBrand(isOrg ? id : null);
  const done = useLore({ scope: LORE_SCOPE.DONE });
  const coverRef = useRef(null);
  const learned = useLoreFacts(isOrg ? { kind: 'organization', domain: id } : { kind: 'person', address: id });

  const match = (i) => (isOrg ? i.domain === id : i.address === id);
  // ponytail: plain filters over a few hundred rows; memoize if a page ever lags.
  const mine = lore.items.filter(match);
  const recent = done.items.filter(match).sort((a, b) => b.at - a.at).slice(0, RECENT_DONE);
  const people = entitiesFrom([...mine, ...recent]).people;
  const openItems = mine.filter((i) => i.bucket !== LORE_BUCKET.HANDLED);
  const person = !isOrg ? people.find((p) => p.address === id) : null;
  const hits = learned.hits;
  // A name someone typed by hand wins over the brand lookup and the sender header.
  const named = hits.find((h) => h.entity?.name_locked)?.entity.name;
  const name = named || (isOrg ? (brand?.name || domainLabel(id)) : (person?.name || id));
  const kindLabel = LORE_KIND_LABEL[hits[0]?.entity?.kind] || (isOrg ? 'Organization' : 'Person');
  const personDomain = person?.domain || null;
  const lastAt = Math.max(0, ...mine.map((i) => i.at), ...recent.map((i) => i.at));

  // The organization's colour runs a gradient into the space cover.
  useEffect(() => {
    const el = coverRef.current;
    if (!el) return;
    if (brand?.accent) el.style.setProperty('--cover-tint', brand.accent);
    else el.style.removeProperty('--cover-tint');
  }, [brand?.accent]);

  const buckets = [...new Set(openItems.map((i) => i.bucket))];
  return (
    <>
      {/* Site preview images (og:image) are cards and screenshots — they make poor
          covers, so the cover is the space header tinted with the brand colour. */}
      <div ref={coverRef} className={`${styles.cover} ${brand?.accent ? styles.coverBrand : ''}`} aria-hidden="true" />
      <div className={styles.page}>
        <div className={styles.pageIcon}>
          <EntityIcon domain={isOrg ? id : null} name={name} kind={isOrg ? 'org' : 'person'} size="lg" />
        </div>
        <h1 className={styles.title}>{name}</h1>

        <div className={styles.props}>
          <div className={styles.prop}>
            <span className={styles.propKey}>Type</span>
            <span className={styles.propValue}><span className={styles.tag}>{kindLabel}</span></span>
          </div>
          {isOrg ? (
            <div className={styles.prop}><span className={styles.propKey}>Website</span><span className={styles.propValue}>{id}</span></div>
          ) : (
            <>
              <div className={styles.prop}><span className={styles.propKey}>Address</span><span className={styles.propValue}>{id}</span></div>
              {personDomain && (
                <div className={styles.prop}>
                  <span className={styles.propKey}>Works at</span>
                  <span className={styles.propValue}><Mention domain={personDomain} name={domainLabel(personDomain)} onClick={() => navigate(LORE_PATH.ORG(personDomain))} /></span>
                </div>
              )}
            </>
          )}
          {isOrg && (
            <div className={styles.prop}>
              <span className={styles.propKey}>People</span>
              <span className={styles.propValue}>
                {people.map((p) => <Mention key={p.address} name={p.name} kind="person" onClick={() => navigate(LORE_PATH.PERSON(p.address))} />)}
                {!people.length && '—'}
              </span>
            </div>
          )}
          <div className={styles.prop}>
            <span className={styles.propKey}>Open with you</span>
            <span className={styles.propValue}>
              {buckets.length ? buckets.map((b) => <span key={b} className={`${styles.tag} ${styles[`tag_${b}`]}`}>{BUCKET_TAG[b]}</span>) : 'Nothing open'}
            </span>
          </div>
          <div className={styles.prop}><span className={styles.propKey}>Last mail</span><span className={styles.propValue}>{lastLabel(lastAt)}</span></div>
        </div>

        <h2 className={styles.h2}>Open work <span className={styles.h2Count}>{openItems.length}</span></h2>
        {openItems.length
          ? openItems.map((i) => <LoreItem key={i.uid} item={i} showBucket onToggle={lore.complete} onOpen={open} onEntity={toEntity} onSendTo={ctx.sendTo} />)
          : <p className={styles.muted}>Nothing open with {name}.</p>}

        {isOrg && people.length > 0 && (
          <>
            <h2 className={styles.h2}>People <span className={styles.h2Count}>{people.length}</span></h2>
            <div className={styles.gallery}>
              {people.map((p) => (
                <button key={p.address} type="button" className={`${styles.card} ${styles.cardBody}`} onClick={() => navigate(LORE_PATH.PERSON(p.address))}>
                  <EntityIcon name={p.name} kind="person" size="md" />
                  <span className={styles.cardTitle}>{p.name}</span>
                  <span className={styles.cardText}>{p.address}</span>
                  <span className={styles.cardFoot}>{p.count} {p.count === 1 ? 'thread' : 'threads'}</span>
                </button>
              ))}
            </div>
          </>
        )}

        <h2 className={styles.h2}>Learned from mail <span className={styles.h2Rule}>Found in your mail</span></h2>
        {hits.map((h) => (
          <div key={h.store?.orgId || 'device'}>
            {h.store && (
              <EntityActions
                hit={h}
                showStore={hits.length > 1}
                onChanged={learned.refresh}
                onGone={(target) => navigate(target ? entityPath(target) : LORE_PATH.TODAY)}
              />
            )}
            {h.facts.map((f) => (
              <div key={f.id || `${f.kind}|${f.name}|${f.value}|${f.related?.name || ''}`} className={`${styles.learn} ${styles.learnRow}`}>
                <div className={styles.learnBody}>
                  <div>
                    <b>{f.related ? `${f.name.replace(/_/g, ' ')} ${f.related.name}` : `${f.name.replace(/_/g, ' ')}: ${f.value}`}</b>
                  </div>
                  {f.quote && <div className={styles.quote}>“{f.quote}”</div>}
                </div>
                {h.store && f.id != null && <FactActions hit={h} fact={f} onChanged={learned.refresh} />}
              </div>
            ))}
          </div>
        ))}
        {!hits.some((h) => h.facts.length) && <p className={styles.muted}>{learned.loading ? 'Loading…' : 'Nothing mined yet for this one.'}</p>}

        <h2 className={styles.h2}>Recently done <span className={styles.h2Rule}>Archived from Lore or the inbox</span></h2>
        {recent.length ? recent.map((i) => (
          <div key={i.uid} className={styles.history}>
            <Icon name="checkmark.circle.fill" size={14} />
            <span className={styles.historyText}>
              <button type="button" className={styles.itemTitle} onClick={() => open(i)}>{i.subject}</button>
            </span>
            <span className={`${styles.tag} ${styles[`tag_${i.bucket}`]}`}>{i.labelName || BUCKET_TAG[i.bucket]}</span>
            <span className={styles.age}>{ageLabel(i.at)}</span>
          </div>
        )) : <p className={styles.muted}>{done.loading ? 'Loading…' : 'Nothing archived recently.'}</p>}
      </div>
    </>
  );
}
