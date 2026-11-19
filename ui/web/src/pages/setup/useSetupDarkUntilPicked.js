import { useEffect } from 'react'
import useTheme from '../../hooks/useTheme'

// Setup shows the plain Dark theme until the Look step picks one (the app's own
// default, Warm, would otherwise colour the wizard before you chose anything).
export const THEME_PICKED_KEY = 'inbox2_setup_theme_picked'

export default function useSetupDarkUntilPicked() {
  const { setTheme } = useTheme()
  useEffect(() => {
    if (!localStorage.getItem(THEME_PICKED_KEY)) setTheme('dark')
  }, [setTheme])
}
