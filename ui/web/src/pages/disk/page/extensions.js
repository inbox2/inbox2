// The extra blocks a Disk page adds to the shared RichEditor (Tiptap 3):
// tables, to-dos, callouts and Disk file cards (spec F6).
import { Node, mergeAttributes } from '@tiptap/core'
import { ReactNodeViewRenderer } from '@tiptap/react'
import { TaskList, TaskItem } from '@tiptap/extension-list'
import { TableKit } from '@tiptap/extension-table'
import DiskFileCard from './DiskFileCard'

/** A note box: <div data-callout>, "> [!NOTE]" in markdown. */
export const Callout = Node.create({
  name: 'callout',
  group: 'block',
  content: 'block+',
  defining: true,
  parseHTML: () => [{ tag: 'div[data-callout]' }],
  renderHTML: ({ HTMLAttributes }) => ['div', mergeAttributes(HTMLAttributes, { 'data-callout': '' }), 0],
  addCommands() {
    return { setCallout: () => ({ commands }) => commands.wrapIn(this.name) }
  },
})

/** A Disk file as a card. Options: orgId, onOpen(node). */
export const DiskFile = Node.create({
  name: 'diskFile',
  group: 'block',
  atom: true,
  draggable: true,
  addOptions: () => ({ orgId: null, onOpen: null }),
  addAttributes: () => ({
    nodeId: { default: null, parseHTML: (el) => el.getAttribute('data-disk-file') },
    name: { default: '', parseHTML: (el) => el.getAttribute('data-name') || el.textContent },
  }),
  parseHTML: () => [{ tag: 'div[data-disk-file]' }],
  renderHTML: ({ node }) => ['div', { 'data-disk-file': node.attrs.nodeId, 'data-name': node.attrs.name }, node.attrs.name],
  addNodeView() {
    return ReactNodeViewRenderer(DiskFileCard)
  },
})

/** Everything a page adds, configured for one org and a card-open handler. */
export function pageExtensions({ orgId, onOpenFile }) {
  return [
    TaskList,
    TaskItem.configure({ nested: true }),
    TableKit.configure({ table: { resizable: false } }),
    Callout,
    DiskFile.configure({ orgId, onOpen: onOpenFile }),
  ]
}
