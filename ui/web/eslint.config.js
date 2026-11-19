// For more info, see https://github.com/storybookjs/eslint-plugin-storybook#configuration-flat-config-format
import storybook from "eslint-plugin-storybook";

import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import reactPlugin from 'eslint-plugin-react'
import jsxA11y from 'eslint-plugin-jsx-a11y'
import { defineConfig, globalIgnores } from 'eslint/config'

const MOUSEDOWN_RULE = {
  selector: "CallExpression[callee.object.name='document'][callee.property.name='addEventListener'][arguments.0.value='mousedown']",
  message: 'use useDismiss (hooks/useDismiss) instead of a hand-rolled document mousedown listener.',
}
const CHECKBOX_RULE = {
  selector: "JSXOpeningElement[name.name='input'] > JSXAttribute[name.name='type'] > Literal[value='checkbox']",
  message: 'Raw checkboxes are off the catalog: use MgmtCheckbox (components/management) or Checkbox.',
}

export default defineConfig([globalIgnores(['dist', 'storybook-static', 'test-results', 'playwright-report']), {
  // Node-context tooling: vite config, the Playwright config, and the e2e specs.
  files: ['vite.config.js', 'playwright.config.js', 'e2e/**/*.js'],
  languageOptions: {
    globals: globals.node,
  },
}, {
  files: ['**/*.{js,jsx}'],
  extends: [
    js.configs.recommended,
    reactHooks.configs.flat.recommended,
    reactRefresh.configs.vite,
  ],
  plugins: {
    react: reactPlugin,
    'jsx-a11y': jsxA11y,
  },
  languageOptions: {
    globals: globals.browser,
    parserOptions: { ecmaFeatures: { jsx: true } },
  },
  rules: {
    // F4 — keyboard operability. Warnings until the backlog is cleared, then errors.
    'jsx-a11y/click-events-have-key-events': 'error',
    'jsx-a11y/no-static-element-interactions': 'error',
    'jsx-a11y/interactive-supports-focus': 'error',
    // F1.3 — No inline styles. All presentation lives in CSS modules.
    'react/forbid-component-props': ['error', {
      forbid: [{
        propName: 'style',
        message: 'Inline styles are prohibited (spec F1.3). Use CSS modules instead.',
      }],
    }],
    'react/forbid-dom-props': ['error', {
      forbid: [{
        propName: 'style',
        message: 'Inline styles are prohibited (spec F1.3). Use CSS modules instead.',
      }],
    }],
    // Keep code-split modules lazy. These are loaded via `await import(...)` on
    // purpose; a *static* import pulls them into the main bundle and triggers
    // Vite's INEFFECTIVE_DYNAMIC_IMPORT warning (the dynamic import elsewhere
    // then no longer splits anything). Import them dynamically instead.
    'no-restricted-imports': ['error', {
      patterns: [{
        group: [
          '**/providers/index',
          '**/providers/index.js',
          '**/lib/providers',
          '**/gmail-oauth',
          '**/gmail-oauth.js',
          '**/microsoft-oauth',
          '**/microsoft-oauth.js',
        ],
        message: 'This module is code-split — load it with `await import(...)`, not a static import (a static import defeats the split and triggers Vite\'s INEFFECTIVE_DYNAMIC_IMPORT warning).',
      }],
    }],
  },
}, {
  // Mail / search / calendar / command / dashboard surfaces read MX data
  // through lib/localFirstApi so the desktop serves them from the local mirror
  // (docs/MX-Sync.md). Same code-split patterns as above — a scoped override
  // replaces the whole rule, so they are repeated here.
  files: ['src/pages/inbox/**', 'src/pages/search/**', 'src/pages/calendar/**', 'src/pages/command/**', 'src/pages/dashboard/**', 'src/mobile/**'],
  rules: {
    'no-restricted-imports': ['error', {
      patterns: [{
        group: [
          '**/providers/index',
          '**/providers/index.js',
          '**/lib/providers',
          '**/gmail-oauth',
          '**/gmail-oauth.js',
          '**/microsoft-oauth',
          '**/microsoft-oauth.js',
        ],
        message: 'This module is code-split — load it with `await import(...)`, not a static import (a static import defeats the split and triggers Vite\'s INEFFECTIVE_DYNAMIC_IMPORT warning).',
      }, {
        group: ['**/lib/api', '**/lib/api.js'],
        message: 'MX reads go through lib/localFirstApi (docs/MX-Sync.md)',
      }],
    }],
  },
}, {
  // Two house rules on syntax, scoped by directory below:
  //  - outside-click dismissal goes through hooks/useDismiss (one primitive,
  //    Escape included); the listed popover primitives own their listeners.
  //  - a raw <input type="checkbox"> is MgmtCheckbox (components/management)
  //    or Checkbox; only those catalog files (and Switch) render the element.
  files: ['src/**/*.{js,jsx}'],
  rules: {
    'no-restricted-syntax': ['error', MOUSEDOWN_RULE, CHECKBOX_RULE],
  },
}, {
  files: ['src/hooks/**', 'src/components/Popover/**', 'src/components/DropdownMenu/**', 'src/components/Tooltip/**'],
  rules: { 'no-restricted-syntax': ['error', CHECKBOX_RULE] },
}, {
  files: ['src/components/Checkbox/**', 'src/components/management/**', 'src/components/Switch/**'],
  rules: { 'no-restricted-syntax': ['error', MOUSEDOWN_RULE] },
}, ...storybook.configs["flat/recommended"]])
