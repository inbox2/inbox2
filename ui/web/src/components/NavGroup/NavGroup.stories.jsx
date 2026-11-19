import NavGroup, { NavItem } from './NavGroup'

export default {
  title: 'Components/NavGroup',
  component: NavGroup,
}

export const Folders = {
  render: () => (
    <div data-theme="dark">
      <NavGroup icon="tray.fill" title="Folders">
        <NavItem icon="tray.fill" label="All Mail" active badge="12" />
        <NavItem icon="person.fill" label="Assigned to me" badge="3" />
        <NavItem icon="bubble.left.fill" label="Mentioned" badge="1" />
        <NavItem icon="paperplane.fill" label="Sent" />
        <NavItem icon="doc.text.fill" label="Drafts" badge="2" />
        <NavItem icon="archivebox.fill" label="Archived" />
        <NavItem icon="xmark.bin.fill" label="Trash" />
      </NavGroup>
    </div>
  ),
}

export const Views = {
  render: () => (
    <div data-theme="dark">
      <NavGroup icon="tag.fill" title="Views">
        <NavItem icon="dollarsign.circle.fill" label="Finance" />
        <NavItem icon="wrench.fill" label="Support" active />
        <NavItem icon="handshake.fill" label="Partnerships" />
      </NavGroup>
    </div>
  ),
}
