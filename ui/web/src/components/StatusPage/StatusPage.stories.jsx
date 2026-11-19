import { MemoryRouter } from 'react-router';
import StatusPage from './StatusPage';

export default {
  title: 'Components/StatusPage',
  component: StatusPage,
  decorators: [(Story) => <MemoryRouter><Story /></MemoryRouter>],
};

export const NotFound = {
  args: {
    code: '404',
    title: 'Page not found',
    message: "The page you're looking for doesn't exist or has been moved.",
    linkTo: '/',
    linkLabel: 'Go back to inbox',
  },
};

export const Forbidden = {
  args: {
    code: '403',
    title: "You don't have access",
    message: "You don't have permission to view this page. Contact your administrator if you believe this is an error.",
    linkTo: '/',
    linkLabel: 'Go back to inbox',
  },
};

export const ServerError = {
  args: {
    code: '500',
    title: 'Something went wrong',
    message: 'An unexpected error occurred. Please try again or contact support if the problem persists.',
    linkTo: '/',
    linkLabel: 'Go back to inbox',
  },
};

export const UpgradeRequired = {
  args: {
    code: '\u2B06',
    title: 'Upgrade to add this',
    message: 'This needs a paid plan. Compare plans and upgrade from billing — it takes a moment.',
    linkTo: '/console/billing',
    linkLabel: 'Go to billing & plan',
  },
};
