import '../src/styles/tokens.css'
import '../src/styles/reset.css'

// The four themes defined in tokens.css. Switching sets `data-theme` on the
// document root (and body) so even portaled content (modals, tooltips, popups
// that render to document.body) picks up the right token set.
const THEMES = [
  { value: 'dark', title: 'Dark' },
  { value: 'light', title: 'Light' },
  { value: 'high-contrast', title: 'High contrast' },
  { value: 'solarized', title: 'Solarized' },
]

export const globalTypes = {
  theme: {
    description: 'Design system theme',
    defaultValue: 'dark',
    toolbar: {
      title: 'Theme',
      icon: 'paintbrush',
      items: THEMES,
      dynamicTitle: true,
    },
  },
}

const withTheme = (Story, context) => {
  const theme = context.globals.theme || 'dark'
  // Apply directly (a Storybook decorator re-runs when globals change). Drive the
  // canvas surface from the active theme's tokens; set via JS, not a JSX inline
  // style, so the no-inline-styles lint rule is satisfied.
  if (typeof document !== 'undefined') {
    document.documentElement.setAttribute('data-theme', theme)
    document.body.setAttribute('data-theme', theme)
    document.body.style.background = 'var(--bg-base)'
    document.body.style.color = 'var(--text-primary)'
    document.body.style.fontFamily = 'var(--font-ui)'
  }
  return <Story />
}

export const decorators = [withTheme]

/** @type { import('@storybook/react-vite').Preview } */
const preview = {
  parameters: {
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
    // The theme toolbar (above) drives the surface; keep explicit canvas
    // backgrounds available for one-off contrast checks.
    backgrounds: {
      default: 'theme',
      values: [
        { name: 'theme', value: 'transparent' },
        { name: 'dark', value: '#090a0e' },
        { name: 'light', value: '#ecedf0' },
      ],
    },
    a11y: {
      test: 'todo',
    },
  },
};

export default preview;
