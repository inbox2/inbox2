import AppMenuBridge from './AppMenuBridge'

export default {
  title: 'Components/AppMenuBridge',
  component: AppMenuBridge,
  parameters: {
    docs: {
      description: {
        component:
          'Non-visual bridge: maps native menu accelerators set up in Rust to app behaviour — ⌘W ("menu:close-tab") closes the active in-app browser tab, and ⌘Q / window-close ("menu:quit-request") opens a confirm-before-quit dialog. Mounted once globally and inert on the web build (its event listeners only attach under Tauri). It renders a ConfirmDialog that stays closed until a quit request arrives, so nothing is visible by default.',
      },
    },
  },
}

export const Default = {
  render: () => (
    <div>
      <p>
        AppMenuBridge wires native menu accelerators to app behaviour: ⌘W closes
        the active browser tab, ⌘Q asks for confirmation before quitting. It is a
        global, mostly-invisible bridge — on the web build (Storybook) it attaches
        no listeners and renders a closed confirm dialog, so nothing shows here.
      </p>
      <AppMenuBridge />
    </div>
  ),
}
