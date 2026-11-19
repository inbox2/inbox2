import AuthLayout from './AuthLayout';

export default {
  title: 'Components/AuthLayout',
  component: AuthLayout,
  decorators: [(Story) => <div data-theme="dark"><Story /></div>],
};

export const Default = {
  args: {
    title: 'Log in to Inbox2',
    children: <p>Form content goes here</p>,
  },
};

export const WithForm = {
  args: {
    title: 'Create your Inbox2 account',
    children: (
      <form>
        <div>
          <label htmlFor="demo-username">Username</label>
          <input id="demo-username" type="text" placeholder="username" />
        </div>
        <div>
          <label htmlFor="demo-password">Password</label>
          <input id="demo-password" type="password" placeholder="password" />
        </div>
        <button type="button">Submit</button>
      </form>
    ),
  },
};
