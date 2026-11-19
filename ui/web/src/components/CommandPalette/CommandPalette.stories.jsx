import { MemoryRouter } from 'react-router'
import CommandPalette from './CommandPalette'

export default {
  title: 'Components/CommandPalette',
  component: CommandPalette,
  decorators: [
    (Story) => (
      <MemoryRouter>
        <div data-theme="dark">
          <Story />
        </div>
      </MemoryRouter>
    ),
  ],
}

export const Open = {
  args: {
    open: true,
    onClose: () => {},
  },
}

export const Closed = {
  args: {
    open: false,
    onClose: () => {},
  },
}
