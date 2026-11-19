import { useState } from 'react'
import Modal from './Modal'

export default {
  title: 'Components/Modal',
  component: Modal,
}

export const Default = {
  render: () => {
    const [open, setOpen] = useState(false)
    return (
      <>
        <button onClick={() => setOpen(true)}>Open Modal</button>
        <Modal open={open} onClose={() => setOpen(false)} titleId="modal-story-title">
          <div data-theme="dark">
            <h2 id="modal-story-title">Modal title</h2>
            <p>Modal content goes here. Tab wraps inside the panel; Escape and the overlay close it.</p>
            <button onClick={() => setOpen(false)}>Done</button>
          </div>
        </Modal>
      </>
    )
  },
}
