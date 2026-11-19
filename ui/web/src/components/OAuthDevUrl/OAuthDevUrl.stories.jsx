import OAuthDevUrl from './OAuthDevUrl'

const MOCK_URL =
  'https://accounts.google.com/o/oauth2/v2/auth?client_id=123-abc.apps.googleusercontent.com&redirect_uri=http://localhost:8731/oauth-callback&response_type=code&scope=https://mail.google.com/'

export default {
  title: 'Components/OAuthDevUrl',
  component: OAuthDevUrl,
}

export const Default = {
  render: () => (
    <div>
      <p>
        Dev-mode override shown when the user toggles dev mode with the backtick key during OAuth
        setup. The read-only field lets the auth URL be copied into a different browser; the
        loopback callback still returns to the app.
      </p>
      <OAuthDevUrl url={MOCK_URL} />
    </div>
  ),
}

export const WithOpenButton = {
  render: () => <OAuthDevUrl url={MOCK_URL} onOpen={() => {}} />,
}
