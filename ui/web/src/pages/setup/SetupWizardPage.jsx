import Icon from '../../components/Icon'
import DevModeIndicator from '../../components/DevModeIndicator/DevModeIndicator'
import useSetupWizardState from '../../hooks/useSetupWizardState'
import useSetupDarkUntilPicked from './useSetupDarkUntilPicked'
import IntroStep from './steps/IntroStep'
import WelcomeStep from './steps/WelcomeStep'
import ThemeStep from './steps/ThemeStep'
import AiStep from './steps/AiStep'
import StepTrail from './steps/StepTrail'
import WindowControls from '../../components/Chrome/WindowControls'
import { startDrag } from '../../lib/tauri'
import ProviderSelectStep from './steps/ProviderSelectStep'
import AccountConfigureStep from './steps/AccountConfigureStep'
import MetaConfigureStep from './steps/MetaConfigureStep'
import OAuthWaitingStep from './steps/OAuthWaitingStep'
import EnrichmentStep from './steps/EnrichmentStep'
import CompleteStep from './steps/CompleteStep'
import styles from './setup.module.css'

export default function SetupWizardPage() {
  const {
    step, setStep, isWide, showBackAboveCard, devMode,
    mode, setMode, handleModeSelect, afterLook,
    hasExistingAccounts, skipAccountSetup,
    provider, setProvider, accountForm, accountError, setAccountError, accountLoading,
    handleProviderNext, handleAccountChange, handleAccountSubmit,
    metaForm, handleMetaChange, handleMetaSubmit, metaApps,
    reuseMode, setReuseMode, reuseFrom, setReuseFrom,
    authUrl, openAuthUrl, setOauthState, setOauthRedirectUri,
    afterAI, apolloKey, setApolloKey, inbox2Key, setInbox2Key,
    handleEnrichSave, signInToAccount, handleFinish,
  } = useSetupWizardState()
  useSetupDarkUntilPicked()

  if (step === 'intro') return <IntroStep onDone={() => setStep('welcome')} />

  return (
    <div className={styles.page}>
      <div className={styles.dragRegion} role="presentation" onMouseDown={startDrag}><WindowControls /></div>
      {devMode && <DevModeIndicator className={styles.devIndicator} />}
      {showBackAboveCard && (
        <button type="button" className={styles.backAboveCard} onClick={() => { setProvider(null); setAccountError(null); setStep('welcome') }}>
          <Icon name="chevron.left" size={12} />
          Back
        </button>
      )}
      <div className={isWide ? styles.cardWide : styles.card}>
        <StepTrail step={step} mode={mode} />
        {step === 'welcome' && (
          <WelcomeStep mode={mode} setMode={setMode} onContinue={handleModeSelect} />
        )}
        {step === 'look' && (
          <ThemeStep onContinue={afterLook} />
        )}
        {step === 'account-select' && (
          <ProviderSelectStep provider={provider} setProvider={setProvider} error={accountError} onContinue={handleProviderNext} hasExistingAccounts={hasExistingAccounts} onSkip={skipAccountSetup} />
        )}
        {step === 'account-configure' && (
          <AccountConfigureStep provider={provider} form={accountForm} onChange={handleAccountChange} error={accountError} loading={accountLoading} onSubmit={handleAccountSubmit} onBack={() => setStep('account-select')} />
        )}
        {step === 'meta-configure' && (
          <MetaConfigureStep provider={provider} form={metaForm} onChange={handleMetaChange} error={accountError} loading={accountLoading} onSubmit={handleMetaSubmit} onBack={() => setStep('account-select')} metaApps={metaApps} reuseMode={reuseMode} setReuseMode={setReuseMode} reuseFrom={reuseFrom} setReuseFrom={setReuseFrom} />
        )}
        {(step === 'oauth-waiting' || step === 'oauth-exchanging') && (
          <OAuthWaitingStep step={step} provider={provider} devMode={devMode} authUrl={authUrl} onOpenUrl={openAuthUrl} onCancel={() => { setStep('account-select'); setOauthState(null); setOauthRedirectUri(null) }} />
        )}
        {step === 'ai' && (
          <AiStep onDone={afterAI} />
        )}
        {step === 'enrich' && (
          <EnrichmentStep apolloKey={apolloKey} setApolloKey={setApolloKey} inbox2Key={inbox2Key} setInbox2Key={setInbox2Key} onSave={handleEnrichSave} onSkip={() => setStep('complete')} onSignIn={signInToAccount} />
        )}
        {step === 'complete' && (
          <CompleteStep mode={mode} onFinish={handleFinish} />
        )}
      </div>
    </div>
  )
}
