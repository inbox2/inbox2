import { useState, useMemo, useCallback } from 'react'
import IconButton from '../IconButton'
import TagInput from '../TagInput/TagInput'
import FromSelect from '../FromSelect/FromSelect'
import useContactSuggestions from '../../hooks/useContactSuggestions'
import { parseAddressList, formatMailbox } from '../../lib/emailAddress'
import styles from './ComposeHeader.module.css'

// Use the shared quote/angle-bracket-aware parser so a display name containing
// a comma ("Sadiq, Amina" <amina@x>) stays one recipient. Normalize to this
// component's chip shape: lowercased email, null name when none.
function parseAddresses(str) {
  return parseAddressList(str).map(({ name, email }) => ({
    email: email.toLowerCase(),
    name: name || null,
  }))
}

function serializeAddresses(values) {
  return values.map(v => formatMailbox(v.name, v.email)).join(', ')
}

export default function ComposeHeader({
  toAddress,
  ccAddress,
  bccAddress,
  fromAddress,
  subject,
  orgSlug,
  fromIdentities = [],
  onToChange,
  onCcChange,
  onBccChange,
  onFromChange,
  onSubjectChange,
  onMinimize,
  onClose,
}) {
  const [showCc, setShowCc] = useState(!!ccAddress)
  const [showBcc, setShowBcc] = useState(!!bccAddress)
  const [toQuery, setToQuery] = useState('')
  const [ccQuery, setCcQuery] = useState('')
  const [bccQuery, setBccQuery] = useState('')

  const { contacts } = useContactSuggestions(orgSlug)

  const toValues = useMemo(() => parseAddresses(toAddress), [toAddress])
  const ccValues = useMemo(() => parseAddresses(ccAddress), [ccAddress])
  const bccValues = useMemo(() => parseAddresses(bccAddress), [bccAddress])

  const filterSuggestions = useCallback((query, exclude) => {
    const q = query.trim().toLowerCase()
    if (!q || q.length < 1) return []
    const excludeEmails = new Set(exclude.map(v => v.email))
    return contacts
      .filter(c => !excludeEmails.has(c.email))
      .filter(c =>
        c.email.toLowerCase().includes(q) ||
        (c.name && c.name.toLowerCase().includes(q))
      )
      .slice(0, 8)
  }, [contacts])

  const toSuggestions = useMemo(() => filterSuggestions(toQuery, toValues), [filterSuggestions, toQuery, toValues])
  const ccSuggestions = useMemo(() => filterSuggestions(ccQuery, ccValues), [filterSuggestions, ccQuery, ccValues])
  const bccSuggestions = useMemo(() => filterSuggestions(bccQuery, bccValues), [filterSuggestions, bccQuery, bccValues])

  return (
    <div className={styles.header}>
      <div className={styles.titleBar}>
        <span className={styles.title}>New message</span>
        <div className={styles.controls}>
          <IconButton
            icon="minus"
            iconSize={12}
            size={22}
            onClick={onMinimize}
            aria-label="Minimize"
          />
          <IconButton
            icon="xmark"
            iconSize={12}
            size={22}
            variant="danger"
            onClick={onClose}
            aria-label="Close"
          />
        </div>
      </div>

      <div className={styles.fields}>
        <div className={styles.fieldRow}>
          <label className={styles.fieldLabel}>From</label>
          {fromIdentities.length > 0 ? (
            <FromSelect
              value={fromAddress}
              identities={fromIdentities}
              onChange={onFromChange}
            />
          ) : (
            <input
              className={styles.fieldInput}
              type="text"
              value={fromAddress}
              onChange={e => onFromChange(e.target.value)}
              placeholder="you@example.com"
            />
          )}
        </div>

        <div className={styles.fieldRow}>
          <label className={styles.fieldLabel}>To</label>
          <TagInput
            values={toValues}
            onChange={(vals) => onToChange(serializeAddresses(vals))}
            placeholder="recipient@example.com"
            suggestions={toSuggestions}
            onQueryChange={setToQuery}
          />
          {!showCc && (
            <button
              className={styles.ccToggle}
              onClick={() => setShowCc(true)}
            >
              CC
            </button>
          )}
          {!showBcc && (
            <button
              className={styles.ccToggle}
              onClick={() => setShowBcc(true)}
            >
              BCC
            </button>
          )}
        </div>

        {showCc && (
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel}>CC</label>
            <TagInput
              values={ccValues}
              onChange={(vals) => onCcChange(serializeAddresses(vals))}
              placeholder="cc@example.com"
              suggestions={ccSuggestions}
              onQueryChange={setCcQuery}
            />
          </div>
        )}

        {showBcc && (
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel}>BCC</label>
            <TagInput
              values={bccValues}
              onChange={(vals) => onBccChange(serializeAddresses(vals))}
              placeholder="bcc@example.com"
              suggestions={bccSuggestions}
              onQueryChange={setBccQuery}
            />
          </div>
        )}

        <div className={styles.fieldRow}>
          <label className={styles.fieldLabel}>Subject</label>
          <input
            className={styles.fieldInput}
            type="text"
            dir="auto"
            value={subject}
            onChange={e => onSubjectChange(e.target.value)}
            placeholder="Subject"
          />
        </div>
      </div>
    </div>
  )
}
