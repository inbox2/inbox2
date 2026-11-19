import Composer from './Composer'
import DraftProvider from '../../hooks/DraftProvider'

export default {
  title: 'Components/Composer',
  component: Composer,
  decorators: [
    (Story) => (
      <DraftProvider orgId="test">
        <div data-theme="dark"><Story /></div>
      </DraftProvider>
    ),
  ],
}

export const Default = {}
