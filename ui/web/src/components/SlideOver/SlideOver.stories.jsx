import { useState } from 'react'
import '../../styles/management.css'
import SlideOver from './SlideOver'
import FileTypeIcon, { ActionIcon } from '../FileTypeIcon'
import { MgmtButton } from '../management'
import styles from './SlideOver.stories.module.css'

export default {
  title: 'Disk/SlideOver',
  component: SlideOver,
}

const files = ['Brand guidelines.pdf', 'Q4 plan.docx', 'hero.png']

function Demo() {
  const [index, setIndex] = useState(null)
  const name = files[index]
  return (
    <div className="management">
      {files.map((f, i) => <MgmtButton key={f} variant="glass" size="sm" onClick={() => setIndex(i)}>{f}</MgmtButton>)}
      <SlideOver
        open={index != null}
        onClose={() => setIndex(null)}
        title={name}
        icon={<FileTypeIcon name={name} />}
        onPrev={index > 0 ? () => setIndex(index - 1) : null}
        onNext={index < files.length - 1 ? () => setIndex(index + 1) : null}
        actions={<>
          <MgmtButton variant="dark" size="sm"><ActionIcon name="download" />Download</MgmtButton>
          <MgmtButton variant="glass" size="sm"><ActionIcon name="share" />Share</MgmtButton>
          <MgmtButton variant="glass" size="sm"><ActionIcon name="expand" />Open full</MgmtButton>
        </>}
      >
        <div className={styles.preview}><FileTypeIcon name={name} size={96} /></div>
      </SlideOver>
    </div>
  )
}

export const Default = { render: () => <Demo /> }
