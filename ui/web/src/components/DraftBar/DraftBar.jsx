import { useState } from 'react'
import useDrafts from '../../hooks/useDrafts'
import ConfirmDialog from '../ConfirmDialog'
import DraftPill from './DraftPill'
import styles from './DraftBar.module.css'

export default function DraftBar() {
  const { minimizedDrafts, restoreDraft, closeDraft } = useDrafts()
  const [discardId, setDiscardId] = useState(null)

  if (minimizedDrafts.length === 0) return null

  return (
    <div className={styles.bar} role="toolbar" aria-label="Minimized drafts">
      {minimizedDrafts.map(draft => (
        <DraftPill
          key={draft.id}
          draft={draft}
          onRestore={() => restoreDraft(draft.id)}
          onClose={() => setDiscardId(draft.id)}
        />
      ))}
      <ConfirmDialog
        open={discardId != null}
        title="Discard draft?"
        message="You’ll lose this draft for good."
        confirmLabel="Discard"
        cancelLabel="Keep draft"
        variant="danger"
        onConfirm={() => { closeDraft(discardId); setDiscardId(null) }}
        onCancel={() => setDiscardId(null)}
      />
    </div>
  )
}
