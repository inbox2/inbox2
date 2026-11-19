import { MemoryRouter } from 'react-router';
import SetupWizardPage from './SetupWizardPage';

export default {
  title: 'Pages/SetupWizard',
  component: SetupWizardPage,
  decorators: [
    (Story) => (
      <MemoryRouter initialEntries={['/setup']}>
        <div data-theme="dark" className="storybook-fullscreen">
          <Story />
        </div>
      </MemoryRouter>
    ),
  ],
  parameters: {
    layout: 'fullscreen',
  },
};

export const Welcome = {};
