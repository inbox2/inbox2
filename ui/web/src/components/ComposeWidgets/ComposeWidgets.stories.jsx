import { ComposeAction } from './ComposeWidgets'
import DraftProvider from '../../hooks/DraftProvider'

export default {
  title: 'Components/ComposeWidgets',
  decorators: [
    (Story) => (
      <DraftProvider orgId="test">
        <Story />
      </DraftProvider>
    ),
  ],
}

export const ComposeButton = {
  render: () => <ComposeAction defaultFrom="waseem@inbox2.dev" />,
}
