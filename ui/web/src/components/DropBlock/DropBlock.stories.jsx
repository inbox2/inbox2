import { useEffect } from 'react'
import DropBlock from './DropBlock'
import useDropBlockStore, { STATUS } from '../../stores/dropBlockStore'

// Keep the game in its idle zero-state for the story (the component also installs
// global keyboard/audio handlers and a requestAnimationFrame render loop once a
// game starts — those are exercised in the running app, not driven here).
function IdleGame({ children }) {
  useEffect(() => {
    useDropBlockStore.setState({ status: STATUS.IDLE })
    return () => useDropBlockStore.setState({ status: STATUS.IDLE })
  }, [])
  return children
}

export default {
  title: 'Components/DropBlock',
  component: DropBlock,
  parameters: {
    docs: {
      description: {
        component:
          'The inbox empty-state mini-game (a falling-block puzzle). It is also a small engine: it owns a Canvas render loop (requestAnimationFrame), capture-phase keyboard handlers for movement/rotation/hold/hard-drop, and background music. In the idle zero-state shown here it displays the "Select a conversation" hint plus a "Press ⏎ to play" affordance; pressing Enter (with the playfield focused) starts a game.',
      },
    },
  },
  decorators: [
    (Story) => (
      <IdleGame>
        <Story />
      </IdleGame>
    ),
  ],
}

export const Idle = {
  render: () => <DropBlock />,
}
