import { expect, userEvent, within } from 'storybook/test'
import RichEditor from './RichEditor'

export default {
  title: 'Components/RichEditor',
  component: RichEditor,
}

export const Default = {
  args: {
    placeholder: 'Write your message...',
  },
}

export const WithContent = {
  args: {
    content: '<h2>Hello</h2><p>This is a <strong>rich text</strong> editor with <em>formatting</em>.</p><ul><li>Bullet one</li><li>Bullet two</li></ul>',
  },
}

// Regression guard for a silent killer: two copies of prosemirror-model in
// node_modules make Enter (splitBlock) throw `Can not convert <> to a Fragment`
// — typing still works, so nothing looks broken until you try a new line.
// Duplicates come back on any tiptap bump; package.json `resolutions` pins them.
export const EnterSplitsParagraph = {
  args: { content: '<p>first line</p>' },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await userEvent.click(canvasElement.querySelector('.ProseMirror'))
    await userEvent.keyboard('{Enter}second line')
    await expect(canvas.getByText('second line')).toBeInTheDocument()
    await expect(canvasElement.querySelectorAll('.ProseMirror p')).toHaveLength(2)
  },
}
