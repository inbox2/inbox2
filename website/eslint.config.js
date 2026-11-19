import js from "@eslint/js";
import globals from "globals";
import reactHooks from "eslint-plugin-react-hooks";
import reactPlugin from "eslint-plugin-react";
import { defineConfig, globalIgnores } from "eslint/config";

// Mirrors ui/web/eslint.config.js — same F1.3 inline-style ban, minus the
// Storybook and code-splitting rules that only apply to the app.
export default defineConfig([
  globalIgnores(["build", ".react-router", "assets-src"]),
  {
    // Node-context tooling: the Vite config and the asset/screenshot scripts.
    files: ["vite.config.js", "react-router.config.js", "scripts/**/*.mjs"],
    languageOptions: { globals: globals.node },
  },
  {
    files: ["**/*.{js,jsx}"],
    extends: [js.configs.recommended, reactHooks.configs.flat.recommended],
    plugins: { react: reactPlugin },
    languageOptions: {
      globals: globals.browser,
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    rules: {
      // F1.3 — No inline styles. All presentation lives in CSS modules.
      // Dynamic per-element values go through a CSS custom property instead.
      "react/forbid-component-props": ["error", { forbid: [{ propName: "style", message: "Inline styles are prohibited (spec F1.3). Use CSS modules instead." }] }],
      "react/forbid-dom-props": ["error", { forbid: [{ propName: "style", message: "Inline styles are prohibited (spec F1.3). Use CSS modules instead." }] }],
    },
  },
]);
