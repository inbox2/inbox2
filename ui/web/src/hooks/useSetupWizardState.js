import { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router'
import log from '../lib/log'
import { saveApiKey } from '../lib/inbox2ApiKey'
import { setSecret } from '../lib/secretStore'
import { SETUP_MODE, setSetupMode } from '../lib/setupMode'
import { markAIOnboardingDismissed } from '../lib/ai/onboarding'
import { isTauri } from '../lib/tauri'
import { PROVIDER } from '../lib/providerTypes'
import { groupMetaApps } from '../lib/metaApps'
import syncManager from '../lib/sync-manager'
import useDevMode from './useDevMode'

// Providers that connect via OAuth (loopback redirect) rather than the IMAP
// username/password form. Mirrors the config in hooks/useOAuthFlow.js so the
// onboarding wizard and the in-app "add account" flow behave identically.
const OAUTH_PROVIDERS = {
  [PROVIDER.GMAIL]: {
    tauriCommand: 'start_gmail_oauth',
    oauthModule: () => import('../lib/gmail-oauth.js'),
    eventName: 'gmail-oauth-callback',
    buildAccount: (profile, tokens) => ({
      display_name: profile.emailAddress.split('@')[0],
      email_address: profile.emailAddress,
      provider_type: PROVIDER.GMAIL,
      auth_method: 'oauth2',
      username: profile.emailAddress,
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
    }),
  },
  [PROVIDER.MICROSOFT]: {
    tauriCommand: 'start_microsoft_oauth',
    oauthModule: () => import('../lib/microsoft-oauth.js'),
    eventName: 'microsoft-oauth-callback',
    buildAccount: (profile, tokens) => {
      const email = profile.mail || profile.userPrincipalName
      return {
        display_name: profile.displayName || email.split('@')[0],
        email_address: email,
        provider_type: PROVIDER.MICROSOFT,
        auth_method: 'oauth2',
        username: email,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
      }
    },
  },
}

// The setup wizard's whole state machine: step/progress, the account/Meta/
// enrichment forms, OAuth handshake, and the keyboard-advance behavior. Returns
// everything the page renders; the page itself is just layout.
export default function useSetupWizardState() {
  const navigate = useNavigate()
  const [mode, setMode] = useState(null)
  // First launch opens on the intro film; reduced motion goes straight to Welcome.
  const [step, setStep] = useState(() =>
    window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? 'welcome' : 'intro')

  // Account setup
  const [provider, setProvider] = useState(null)
  const [accountForm, setAccountForm] = useState({
    display_name: '', email_address: '', host: '', port: '993',
    use_tls: true, username: '', password: '',
    smtp_host: '', smtp_port: '465', smtp_use_tls: true,
  })
  const [accountError, setAccountError] = useState(null)
  const [accountLoading, setAccountLoading] = useState(false)
  // Meta BYOK account setup (Instagram/Messenger/WhatsApp).
  const [metaForm, setMetaForm] = useState({
    display_name: '', app_id: '', app_secret: '', system_user_token: '',
    facebook_page_id: '', instagram_account_id: '',
    whatsapp_phone_number_id: '', whatsapp_business_account_id: '',
  })
  // Existing Meta accounts → reuse an app's secret + System User token when
  // adding another channel (only the asset id is then required).
  const [metaAccounts, setMetaAccounts] = useState([])
  const [reuseMode, setReuseMode] = useState('new')
  const [reuseFrom, setReuseFrom] = useState('')
  const metaApps = groupMetaApps(metaAccounts)
  const [oauthState, setOauthState] = useState(null)
  const [oauthRedirectUri, setOauthRedirectUri] = useState(null)
  const oauthRedirectUriRef = useRef(null)
  // Global dev mode (toggle anywhere with `): show the auth URL instead of
  // auto-opening it, so it can be pasted into a different browser. The loopback
  // callback still returns to the app regardless of which browser completes it.
  const devMode = useDevMode()
  const [authUrl, setAuthUrl] = useState(null)

  const openAuthUrl = async () => {
    if (!authUrl) return
    const { invoke } = await import('@tauri-apps/api/core')
    await invoke('plugin:opener|open_url', { url: authUrl })
  }

  // Enrichment / cloud keys
  const [apolloKey, setApolloKey] = useState('')
  const [inbox2Key, setInbox2Key] = useState('')

  // ── Navigation helpers ─────────────────────────────────

  const afterAccountSetup = () => {
    setProvider(null)
    setAccountForm({ display_name: '', email_address: '', host: '', port: '993', use_tls: true, username: '', password: '' })
    if (mode === 'mx') setStep('enrich')
    else setStep('ai')
  }

  const afterAI = () => {
    // The user has been through the AI step (opted in or skipped), so don't
    // pop the one-time AI onboarding modal again on the inbox.
    markAIOnboardingDismissed()
    if (mode === 'mx') setStep('account-select')
    else setStep('enrich')
  }

  // Every route to an inbox2 account ends up on the same screen. /login offers
  // BOTH the username/password form and the browser device-link, so sending the
  // standalone branch here loses nothing and stops the two halves of onboarding
  // authenticating in different ways against different origins.
  //
  // The mode must be written BEFORE navigating: GuestRoute bounces /login back to
  // /setup while setup reads as incomplete, which would be an infinite loop.
  const signInToAccount = () => {
    setSetupMode(SETUP_MODE.MX)
    navigate('/login')
  }

  // Welcome → Look (both paths) → sign in (MX) or connect channels.
  const handleModeSelect = () => {
    if (!mode) return
    setStep('look')
  }

  const afterLook = () => {
    if (mode === 'mx') {
      signInToAccount()
      return
    }
    setStep('account-select')
  }

  // ── Account setup ──────────────────────────────────────

  const handleProviderNext = async () => {
    if (!provider) return
    // Meta BYOK channels collect their app-secret bundle + asset ids on a
    // dedicated form (no OAuth, no IMAP host).
    if (provider.meta) {
      setAccountError(null)
      setStep('meta-configure')
      return
    }
    const oauthConfig = OAUTH_PROVIDERS[provider.type]
    if (oauthConfig) {
      if (!isTauri()) {
        setAccountError(`Sign in to ${provider.label} from the desktop app`)
        return
      }
      setAccountError(null)
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const { state: csrfState, redirect_uri: redirectUri } = await invoke(oauthConfig.tauriCommand)
        const { getAuthUrl } = await oauthConfig.oauthModule()
        const { auth_url: authUrl } = await getAuthUrl(csrfState, redirectUri)
        setAuthUrl(authUrl)
        if (!devMode) {
          await invoke('plugin:opener|open_url', { url: authUrl })
        }
        setOauthState(csrfState)
        setOauthRedirectUri(redirectUri)
        oauthRedirectUriRef.current = redirectUri
        setStep('oauth-waiting')
      } catch (err) {
        setAccountError(err.message || "Couldn't start sign-in")
      }
      return
    }
    setStep('account-configure')
  }

  const handleAccountChange = (field) => (e) => {
    const value = e.target.type === 'checkbox' ? e.target.checked : e.target.value
    setAccountForm(prev => ({ ...prev, [field]: value }))
  }

  const handleAccountSubmit = async (e) => {
    e.preventDefault()
    setAccountError(null)
    setAccountLoading(true)
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      const account = await invoke('add_external_account', {
        request: {
          provider_type: provider.type,
          display_name: accountForm.display_name || accountForm.email_address.split('@')[0],
          email_address: accountForm.email_address,
          host: accountForm.host,
          port: parseInt(accountForm.port, 10),
          use_tls: accountForm.use_tls,
          smtp_host: accountForm.smtp_host || null,
          smtp_port: parseInt(accountForm.smtp_port, 10) || null,
          smtp_use_tls: accountForm.smtp_use_tls,
          username: accountForm.username || accountForm.email_address,
          password: accountForm.password,
        },
      })
      // Registering only parks the adapter as disconnected; connect it now, like
      // the OAuth and Meta paths do. Without this an IMAP account added in the
      // wizard stayed disconnected until the next launch (found 2026-11-07).
      await syncManager.init()
      syncManager.register(account.key)
      invoke('start_sync', { accountKey: account.key })
        .catch(err => log.warn('Sync', `IMAP sync failed: ${err?.message || err}`))
      afterAccountSetup()
    } catch (err) {
      setAccountError(err.message || "Couldn't connect")
    } finally {
      setAccountLoading(false)
    }
  }

  const handleMetaChange = (field) => (e) => {
    setMetaForm(prev => ({ ...prev, [field]: e.target.value }))
  }

  // Whether the local DB already holds channels. The wizard otherwise insists on
  // connecting one before it will finish, which is unreachable when the accounts
  // are already there — a restored/seeded database, or a reinstall over an
  // existing data dir. Drives the "I already have accounts" skip on the provider
  // step. Checked on account-select only; nothing else needs it.
  const [hasExistingAccounts, setHasExistingAccounts] = useState(false)
  useEffect(() => {
    if (step !== 'account-select' || !isTauri()) return undefined
    let cancelled = false
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const accts = await invoke('list_external_accounts')
        if (!cancelled) setHasExistingAccounts((accts || []).length > 0)
      } catch { /* engine not reachable — leave the skip hidden */ }
    })()
    return () => { cancelled = true }
  }, [step])

  // Load existing accounts on entering the Meta step so a second channel can
  // reuse the first's app credentials; default to reuse when any app exists.
  useEffect(() => {
    if (step !== 'meta-configure' || !isTauri()) return undefined
    let cancelled = false
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const accts = await invoke('list_external_accounts')
        if (cancelled) return
        setMetaAccounts(accts || [])
        const apps = groupMetaApps(accts || [])
        if (apps.length > 0) {
          setReuseMode('existing')
          setReuseFrom((prev) => prev || apps[0].repKey)
        }
      } catch { /* no existing accounts to reuse */ }
    })()
    return () => { cancelled = true }
  }, [step])

  const handleMetaSubmit = async (e) => {
    e.preventDefault()
    setAccountError(null)
    if (!isTauri()) {
      setAccountError(`Connect ${provider.label} from the desktop app`)
      return
    }
    setAccountLoading(true)
    const reusing = reuseMode === 'existing' && !!reuseFrom
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      const account = await invoke('add_meta_account', {
        request: {
          channel: provider.type,
          display_name: metaForm.display_name || null,
          app_id: reusing ? '' : metaForm.app_id,
          app_secret: reusing ? '' : metaForm.app_secret,
          system_user_token: reusing ? '' : metaForm.system_user_token,
          facebook_page_id: metaForm.facebook_page_id || null,
          instagram_account_id: metaForm.instagram_account_id || null,
          whatsapp_phone_number_id: metaForm.whatsapp_phone_number_id || null,
          whatsapp_business_account_id: metaForm.whatsapp_business_account_id || null,
          reuse_credentials_from: reusing ? reuseFrom : null,
        },
      })
      // Hand the engine the API context + event bridge before sync, then connect
      // (validates the token, subscribes webhooks, registers the relay).
      await syncManager.init()
      syncManager.register(account.key)
      invoke('start_sync', { accountKey: account.key })
        .catch(err => log.warn('Sync', `Meta sync failed: ${err?.message || err}`))
      afterAccountSetup()
    } catch (err) {
      const msg = typeof err === 'string' ? err : (err?.message || String(err))
      setAccountError(msg || "Couldn't connect")
    } finally {
      setAccountLoading(false)
    }
  }

  // OAuth callback listener (Gmail + Office 365 / Microsoft)
  useEffect(() => {
    if (!isTauri() || step !== 'oauth-waiting') return
    const oauthConfig = provider && OAUTH_PROVIDERS[provider.type]
    if (!oauthConfig) return
    let unlisten = null;
    (async () => {
      const { listen } = await import('@tauri-apps/api/event')
      unlisten = await listen(oauthConfig.eventName, async (event) => {
        try {
          const { code, state } = event.payload || {}
          if (!code) {
            setAccountError("Sign-in didn't finish. Try again.")
            setStep('account-select')
            return
          }
          if (oauthState && state !== oauthState) {
            setAccountError("Sign-in didn't match. Try again.")
            setStep('account-select')
            return
          }

          setStep('oauth-exchanging')

          const { exchangeCode, getProfile } = await oauthConfig.oauthModule()
          log.info('OAuth', 'Exchanging authorization code')
          const tokens = await exchangeCode(code, oauthRedirectUriRef.current)
          log.info('OAuth', 'Token exchange OK, fetching profile')
          const profile = await getProfile(tokens.access_token)

          const { invoke } = await import('@tauri-apps/api/core')
          log.info('OAuth', 'Adding external account')
          const account = await invoke('add_external_account', {
            request: oauthConfig.buildAccount(profile, tokens),
          })

          // Hand the engine the API context (Rails proxy base + JWT) and start
          // bridging events BEFORE syncing — mirrors the main app's
          // startProviderSync. Without this the setup screen never calls
          // set_api_context, so OAuth token refresh fails ("API context not
          // set") and the account shows disconnected until a restart.
          await syncManager.init()
          syncManager.register(account.key)

          // Kick off sync in the Rust engine (mail + calendar).
          invoke('start_sync', { accountKey: account.key })
            .catch(e => log.warn('Sync', `Sync failed: ${e?.message || e}`))

          afterAccountSetup()
        } catch (err) {
          const msg = typeof err === 'string' ? err : (err?.message || String(err))
          log.error('OAuth', `Error: ${msg}`)
          setAccountError(msg || "Couldn't connect the account")
          setStep('account-select')
        }
      })
    })()
    return () => { if (unlisten) unlisten() }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, oauthState, oauthRedirectUri, provider])

  const handleEnrichSave = async () => {
    if (apolloKey.trim()) {
      await setSecret('apollo_api_key', apolloKey.trim())
    }
    // Personal API key (ink_…) becomes the bearer for cloud features (private
    // image proxy + push) on standalone clients. No-op if blank/not a key.
    saveApiKey(inbox2Key)
    setStep('complete')
  }

  // "I already have accounts" — the DB is already populated, so there is nothing
  // to connect. Joins the same tail as a freshly added account (AI → enrichment
  // → complete) rather than jumping to the end, so the AI and enrichment choices
  // are still offered.
  const skipAccountSetup = () => {
    setProvider(null)
    setAccountError(null)
    setStep('ai')
  }

  const handleFinish = () => {
    setSetupMode(mode || SETUP_MODE.STANDALONE)
    navigate('/')
  }

  // Enter advances the wizard on steps with a clear primary action. The IMAP
  // config form submits on Enter itself, and the OAuth-waiting / AI steps are
  // driven by their own components, so they're excluded. Only fire when the
  // step's primary action is actually enabled (mode/provider selected).
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'Enter' || e.isComposing) return
      const t = e.target
      if (t && (t.tagName === 'TEXTAREA' || t.isContentEditable)) return
      // A focused button, link or select owns its Enter (picks that option).
      if (t && ['BUTTON', 'A', 'SELECT'].includes(t.tagName)) return
      switch (step) {
        case 'welcome': if (mode) { e.preventDefault(); handleModeSelect() } break
        case 'look': e.preventDefault(); afterLook(); break
        case 'account-select': if (provider) { e.preventDefault(); handleProviderNext() } break
        case 'enrich': e.preventDefault(); handleEnrichSave(); break
        case 'complete': e.preventDefault(); handleFinish(); break
        default: break
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  // devMode must be a dep: otherwise the Enter handler keeps a stale closure
  // (devMode=false) and auto-opens the browser even after toggling dev mode.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, mode, provider, apolloKey, devMode])

  const isWide = ['welcome', 'look', 'account-select', 'ai'].includes(step)
  // Steps that can return to the mode choice. Picking the wrong card on the
  // welcome screen used to be unrecoverable: only account-select offered a way
  // back, so anyone who reached the AI or enrichment step had to finish the
  // wizard (or clear localStorage) to switch between MX and standalone. The
  // configure/OAuth steps are excluded — they carry their own Back/Cancel to the
  // provider list — and so is 'complete', where the action is Finish.
  const BACK_TO_WELCOME_STEPS = ['look', 'account-select', 'ai', 'enrich']
  const showBackAboveCard = BACK_TO_WELCOME_STEPS.includes(step)

  return {
    // step / layout
    step, setStep, isWide, showBackAboveCard, devMode,
    // welcome
    mode, setMode, handleModeSelect, afterLook,
    hasExistingAccounts, skipAccountSetup,
    // provider select + account config
    provider, setProvider, accountForm, accountError, setAccountError, accountLoading,
    handleProviderNext, handleAccountChange, handleAccountSubmit,
    // meta
    metaForm, handleMetaChange, handleMetaSubmit, metaApps,
    reuseMode, setReuseMode, reuseFrom, setReuseFrom,
    // oauth
    authUrl, openAuthUrl, setOauthState, setOauthRedirectUri,
    // ai + enrichment + finish
    afterAI, apolloKey, setApolloKey, inbox2Key, setInbox2Key,
    handleEnrichSave, signInToAccount, handleFinish,
  }
}
