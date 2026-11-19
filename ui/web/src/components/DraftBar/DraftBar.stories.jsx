import DraftPill from './DraftPill'
import styles from './DraftBar.stories.module.css'

export default {
  title: 'Components/DraftBar',
}

const mockDraft = {
  id: 'msg_1',
  subject: 'Re: Project Update',
  toAddress: 'alice@example.com',
}

export const SinglePill = {
  render: () => (
    <DraftPill
      draft={mockDraft}
      onRestore={() => {}}
      onClose={() => {}}
    />
  ),
}

export const MultiplePills = {
  render: () => (
    <div className={styles.row}>
      <DraftPill
        draft={{ id: '1', subject: 'Re: Project Update', toAddress: '' }}
        onRestore={() => {}}
        onClose={() => {}}
      />
      <DraftPill
        draft={{ id: '2', subject: '', toAddress: 'bob@example.com' }}
        onRestore={() => {}}
        onClose={() => {}}
      />
      <DraftPill
        draft={{ id: '3', subject: '', toAddress: '' }}
        onRestore={() => {}}
        onClose={() => {}}
      />
    </div>
  ),
}
