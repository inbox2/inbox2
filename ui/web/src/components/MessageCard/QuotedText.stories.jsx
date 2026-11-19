import { expect, within } from 'storybook/test'
import QuotedText from './QuotedText'

// Browser-mode (Storybook + addon-vitest) harness for QuotedText's theme-aware
// color rewrite. It lives here, not in the jsdom unit project, because the rewrite
// parses colors through a real <canvas> 2d context — unavailable in jsdom. The
// luma rule: dark text is dropped in dark mode, light text is dropped in light
// mode, and intentional accent colors survive in both. Mirrors the inline colors
// in /fixtures/email/cases/dark-text-colors.html.
//
// Each story forces a theme via the data-theme attribute QuotedText reads, then the
// play function asserts which inline colors were stripped.

const COLOR_HTML =
  '<p id="t-dark" style="color:#111111">Dark body text</p>' +
  '<p id="t-light" style="color:#ffffff">Light body text</p>' +
  '<p id="t-accent" style="color:#1a73e8">Accent link text</p>'

const withTheme = (mode) => (Story) => {
  document.documentElement.setAttribute('data-theme', mode)
  return <Story />
}

export default {
  title: 'Components/QuotedText',
  component: QuotedText,
}

// Dark mode: the near-black text is unreadable on the dark app surface → stripped.
// White text stays (readable), accent stays (intentional).
export const DarkTheme = {
  decorators: [withTheme('dark')],
  render: () => <QuotedText html={COLOR_HTML} />,
  play: async ({ canvasElement }) => {
    const c = within(canvasElement)
    expect(c.getByText('Dark body text').style.color).toBe('')
    expect(c.getByText('Light body text').style.color).not.toBe('')
    expect(c.getByText('Accent link text').style.color).not.toBe('')
  },
}

// Light mode: the white text is unreadable on the white page → stripped.
// Near-black text stays (readable), accent stays (intentional).
export const LightTheme = {
  decorators: [withTheme('light')],
  render: () => <QuotedText html={COLOR_HTML} />,
  play: async ({ canvasElement }) => {
    const c = within(canvasElement)
    expect(c.getByText('Light body text').style.color).toBe('')
    expect(c.getByText('Dark body text').style.color).not.toBe('')
    expect(c.getByText('Accent link text').style.color).not.toBe('')
  },
}
