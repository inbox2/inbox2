import Tooltip from '../Tooltip'
import IconButton from '../IconButton'
import DropdownMenu from '../DropdownMenu/DropdownMenu'

export default function MessageActions({ items }) {
  return (
    <DropdownMenu
      trigger={
        <Tooltip content="Message actions">
          <IconButton icon="ellipsis" size={24} aria-label="Message actions" />
        </Tooltip>
      }
      items={items}
    />
  )
}
