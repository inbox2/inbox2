import NoteCard from './NoteCard'

export default {
  title: 'Components/NoteCard',
  component: NoteCard,
}

export const Default = {
  args: {
    author: 'Waseem Sadiq',
    time: 'Today 10:50 AM',
    children: '@alex Let\'s loop in the finance team before the board deck.',
  },
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
}
