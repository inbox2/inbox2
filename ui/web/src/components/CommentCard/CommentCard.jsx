import { useEffect, useMemo, useRef } from 'react'
import Avatar from '../Avatar'
import Icon from '../Icon'
import { displayName as senderName, emailOnly } from '../../lib/emailAddress'
import { stripHtml } from '../../lib/messageText'
import { linkifyText } from '../../lib/linkifyText'
import { openLink, handleAnchorClick } from '../../lib/openLink'
import { brandFor, brandVars, META_KIND } from '../../lib/providerTypes'
import styles from './CommentCard.module.css'

// Parse "commented on your post <a href=…>Title</a>:" → { surface, title, url }.
// The post/reel is the "source"; its permalink (when present) makes the title a
// clickable link. Falls back gracefully when the provider sent no context HTML.
function parseContext(html, isMention) {
  if (!html) return { surface: isMention ? 'mention' : 'post', title: '', url: null }
  // Inert parse (no script exec, no resource load) — the provider context HTML is
  // untrusted and must not run in the app origin. See stripHtml in lib/messageText.
  const tmp = new DOMParser().parseFromString(html, 'text/html').body
  const text = (tmp.textContent || '').trim()
  const a = tmp.querySelector('a')
  const m = text.match(/your\s+(\w+)\s+(.+?):?\s*$/i)
  return {
    surface: m ? m[1].toLowerCase() : (isMention ? 'mention' : 'post'),
    title: a ? a.textContent.trim() : (m ? m[2].trim() : ''),
    url: a ? a.getAttribute('href') : null,
    // Post/media thumbnail — in production this is the Graph API's
    // media.thumbnail_url (IG) / post.full_picture (FB); the demo carries it on
    // the context link as data-thumb.
    thumb: a ? a.getAttribute('data-thumb') : null,
  }
}

// The dedicated surface for social comments and mentions (kind = comment |
// mention). Styled after Instagram's own comment UI: avatar, bold username then
// the comment inline, with a quiet Reply + like — not an email-style card.
export default function CommentCard({ conversation }) {
  const wrapRef = useRef(null)
  const brand = brandFor(conversation)

  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    for (const [name, value] of brandVars(brand)) el.style.setProperty(name, value)
  }, [brand])

  const { comment, replies } = useMemo(() => {
    const msgs = conversation.messages ?? []
    const firstInboundIdx = msgs.findIndex(m => m.is_inbound)
    const idx = firstInboundIdx === -1 ? 0 : firstInboundIdx
    return { comment: msgs[idx], replies: msgs.filter((_, i) => i !== idx) }
  }, [conversation.messages])

  const isMention = conversation.kind === META_KIND.MENTION
  const author = senderName(comment?.from_address) || comment?.from_address || 'Someone'
  const { surface, title, url, thumb } = parseContext(comment?.body_html, isMention)
  const openPost = url ? (e) => { e.preventDefault(); openLink(url, { forceExternal: e.metaKey || e.ctrlKey }) } : undefined
  const commentText = (comment?.body_plain || stripHtml(comment?.body_html) || '').trim()
  const time = comment ? new Date(comment.created_at).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : ''

  return (
    <div ref={wrapRef} className={styles.wrap}>
      <div className={styles.scroll}>
        <article className={styles.card}>
          {/* Quiet context line — which post/reel this is on. */}
          <div className={styles.context}>
            <img src={brand.logo} alt={brand.label} width={14} height={14} className={styles.logo} />
            <span className={styles.contextText}>
              {isMention ? 'Mentioned you' : `Comment on your ${surface}`}
              {title && <>{' · '}
                {url
                  ? <a href={url} className={styles.postLink} onClick={openPost}>{title}</a>
                  : <span className={styles.postTitle}>{title}</span>}
              </>}
            </span>
            <span className={styles.time}>{time}</span>
          </div>

          {/* Post preview — thumbnail + title, opens the post on the platform.
              (Graph API: media.thumbnail_url / post.full_picture + permalink.) */}
          {(thumb || (url && title)) && (
            <a
              className={styles.postPreview}
              href={url || undefined}
              onClick={openPost}
              rel="noreferrer"
            >
              {thumb
                ? <img src={thumb} alt="" className={styles.postThumb} />
                : <span className={styles.postThumbFallback}><Icon name="photo" size={18} /></span>}
              <span className={styles.postPreviewInfo}>
                <span className={styles.postPreviewTitle}>{title || `${brand.label} ${surface}`}</span>
                <span className={styles.postPreviewMeta}>View on {brand.label}</span>
              </span>
              <Icon name="chevron.right" size={14} className={styles.postPreviewChevron} />
            </a>
          )}

          {/* The comment, Instagram-style: avatar, bold username + text inline. */}
          <div className={styles.commentRow}>
            <Avatar name={author} email={emailOnly(comment?.from_address)} src={conversation.from_avatar} size={40} />
            <div className={styles.main}>
              <p className={styles.line} role="presentation" onClick={handleAnchorClick}>
                <span className={styles.username}>{author}</span>{' '}
                <span className={styles.text} dangerouslySetInnerHTML={{ __html: linkifyText(commentText) }} />
              </p>
              <div className={styles.actions}>
                <button type="button" className={styles.reply}>Reply</button>
              </div>
            </div>
            <button type="button" className={styles.like} aria-label="Like">
              <Icon name="heart" size={16} />
            </button>
          </div>

          {replies.length > 0 && (
            <div className={styles.replies} role="presentation" onClick={handleAnchorClick}>
              {replies.map((r, i) => {
                const outbound = !r.is_inbound
                const who = outbound ? 'You' : (senderName(r.from_address) || author)
                return (
                  <div key={r.id || r.key || i} className={styles.replyRow}>
                    <span className={outbound ? styles.replyYou : styles.replyAuthor}>{who}</span>{' '}
                    <span
                      className={styles.replyText}
                      dangerouslySetInnerHTML={{ __html: linkifyText((r.body_plain || stripHtml(r.body_html) || '').trim()) }}
                    />
                  </div>
                )
              })}
            </div>
          )}
        </article>
      </div>
    </div>
  )
}
