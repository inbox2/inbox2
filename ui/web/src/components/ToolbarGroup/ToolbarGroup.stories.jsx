import ToolbarGroup, { ToolbarButton } from './ToolbarGroup'

export default {
  title: 'Components/ToolbarGroup',
  component: ToolbarGroup,
}

export const SingleButton = {
  render: () => <ToolbarButton icon="arrowshape.turn.up.left">Reply</ToolbarButton>,
}

export const ButtonGroup = {
  render: () => (
    <div data-theme="dark">
      <ToolbarGroup>
        <ToolbarButton icon="arrowshape.turn.up.left">Reply</ToolbarButton>
        <ToolbarButton icon="arrowshape.turn.up.left.2">All</ToolbarButton>
        <ToolbarButton icon="arrowshape.turn.up.right">Fwd</ToolbarButton>
        <ToolbarButton icon="archivebox.fill">Archive</ToolbarButton>
        <ToolbarButton icon="tag.fill">Tag</ToolbarButton>
        <ToolbarButton icon="person.badge.plus">Assign</ToolbarButton>
      </ToolbarGroup>
    </div>
  ),
}

export const ComposeButton = {
  render: () => <ToolbarButton icon="square.and.pencil" variant="compose">Compose</ToolbarButton>,
}

export const SendButton = {
  render: () => <ToolbarButton icon="paperplane.fill">Send</ToolbarButton>,
}

export const ChromeButton = {
  render: () => (
    <div data-theme="dark">
      <ToolbarButton icon="sun.max.fill" variant="chrome" />
    </div>
  ),
}
