import Tooltip from './Tooltip'

export default {
  title: 'Components/Tooltip',
  component: Tooltip,
}

export const Default = {
  render: () => (
    <div>
      <Tooltip content="Archive this conversation">
        <button>Hover me</button>
      </Tooltip>
    </div>
  ),
}

export const LongText = {
  render: () => (
    <div>
      <Tooltip content="⌘K to open command palette">
        <button>Keyboard shortcut</button>
      </Tooltip>
    </div>
  ),
}
