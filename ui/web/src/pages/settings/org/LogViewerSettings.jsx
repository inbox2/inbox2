import { useState, useEffect, useRef, useCallback } from 'react'
import log from '../../../lib/log'
import SegmentedControl from '../../../components/SegmentedControl'
import useCopyToClipboard from '../../../hooks/useCopyToClipboard'
import styles from './LogViewerSettings.module.css'

const LEVEL_ACCENTS = {
  ERROR: 'var(--status-danger-text)',
  WARN: 'var(--status-warn-text)',
  INFO: 'var(--status-info-text)',
  DEBUG: 'var(--status-debug-text)',
}

export default function LogViewerSettings() {
  const [entries, setEntries] = useState(() => [...log.entries])
  const [filter, setFilter] = useState('')
  const [levelFilter, setLevelFilter] = useState('all')
  const [paused, setPaused] = useState(false)
  const logEndRef = useRef(null)
  const pausedRef = useRef(false)
  const [copied, copy] = useCopyToClipboard()

  // Keep pausedRef in sync
  useEffect(() => { pausedRef.current = paused }, [paused])

  // Subscribe to live log stream
  useEffect(() => {
    return log.subscribe(() => {
      if (!pausedRef.current) {
        setEntries([...log.entries])
      }
    })
  }, [])

  // Auto-scroll on new entries
  useEffect(() => {
    if (!paused && logEndRef.current) {
      logEndRef.current.scrollIntoView({ behavior: 'smooth' })
    }
  }, [entries.length, paused])

  const filtered = entries.filter(e => {
    if (levelFilter !== 'all' && e.level !== levelFilter) return false
    if (filter) {
      const q = filter.toLowerCase()
      return e.tag.toLowerCase().includes(q) || e.message.toLowerCase().includes(q)
    }
    return true
  })

  const handleCopy = useCallback(() => {
    const text = filtered
      .map(e => `[${e.time}] ${e.level} [${e.tag}] ${e.message}`)
      .join('\n')
    copy(text)
  }, [filtered, copy])

  const handleExport = useCallback(() => {
    const text = filtered
      .map(e => `[${e.time}] ${e.level} [${e.tag}] ${e.message}`)
      .join('\n')
    const blob = new Blob([text], { type: 'text/plain' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `inbox2-logs-${new Date().toISOString().slice(0, 10)}.txt`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }, [filtered])

  const counts = {
    error: entries.filter(e => e.level === 'ERROR').length,
    warn: entries.filter(e => e.level === 'WARN').length,
    info: entries.filter(e => e.level === 'INFO').length,
    debug: entries.filter(e => e.level === 'DEBUG').length,
  }

  return (
    <div className={styles.root}>
      <h2 className={styles.title}>App logs</h2>
      <p className={styles.desc}>
        Copy or export these logs to send to support.
      </p>

      {/* ── Controls ─── */}
      <div className={styles.toolbar}>
        <input
          className={styles.filterInput}
          placeholder="Filter by tag or message…"
          value={filter}
          onChange={e => setFilter(e.target.value)}
        />
        <SegmentedControl
          aria-label="Filter by log level"
          value={levelFilter}
          onChange={setLevelFilter}
          options={['all', 'ERROR', 'WARN', 'INFO', 'DEBUG'].map(lvl => ({
            value: lvl,
            label: lvl === 'all' ? 'All' : lvl,
            count: lvl === 'all' ? undefined : (counts[lvl.toLowerCase()] || 0),
            accent: LEVEL_ACCENTS[lvl],
          }))}
        />
        <div className={styles.toolbarActions}>
          <button className={styles.actionBtn} onClick={() => setPaused(p => !p)} title={paused ? 'Resume' : 'Pause'}>
            {paused ? '\u25B6 Resume' : '\u23F8 Pause'}
          </button>
          <button className={styles.actionBtn} onClick={handleCopy} title="Copy to clipboard">
            {copied ? '\u2713 Copied' : '\u2398 Copy'}
          </button>
          <button className={styles.actionBtn} onClick={handleExport} title="Export as .txt file">
            \u2913 Export
          </button>
        </div>
      </div>

      {/* ── Log entries ─── */}
      <div className={styles.logWindow}>
        {filtered.length === 0 && (
          <div className={styles.logEmpty}>
            {entries.length === 0
              ? 'No log entries yet. They show up as you use the app.'
              : 'No entries match the current filter.'}
          </div>
        )}
        {filtered.map((entry, i) => (
          <div key={i} className={styles.logEntry}>
            <span className={styles.logTime}>{entry.time}</span>
            <span className={`${styles.logLevel} ${styles[`log${entry.level}`]}`}>
              {entry.level}
            </span>
            <span className={styles.logTag}>{entry.tag}</span>
            <span className={styles.logMessage}>{entry.message}</span>
          </div>
        ))}
        <div ref={logEndRef} />
      </div>

      <p className={styles.hint}>
        Showing the last {entries.length} entries from this session. The desktop app also saves them to disk.
      </p>
    </div>
  )
}
