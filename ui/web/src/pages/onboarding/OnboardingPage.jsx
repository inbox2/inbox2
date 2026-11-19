import { useState } from 'react';
import { useNavigate } from 'react-router';
import api from '../../lib/api';
import Icon from '../../components/Icon';
import DnsVerify from '../../components/DnsRecordsTable/DnsVerify';
import MailboxStep from './MailboxStep';
import { ManagementLayout, MgmtCard, MgmtField, MgmtButton } from '../../components/management';
import useAuth from '../../hooks/useAuth';
import styles from './onboarding.module.css';
import { consolePath } from '../../lib/consoleHost';

const STEP_COUNT = 4;

export default function OnboardingPage() {
  const [step, setStep] = useState(0);
  const [domain, setDomain] = useState('');
  const [orgId, setOrgId] = useState(null);
  // Set only when adding a domain to an EXISTING org — drives DnsVerify to use the
  // per-domain endpoints. null for the first-org signup (org-primary domain).
  const [domainKey, setDomainKey] = useState(null);
  // The just-created domain's dom_ key — needed to assign mailboxes on it. Set in
  // BOTH paths (unlike domainKey, which stays null for the primary domain so
  // DnsVerify targets the org-level DNS endpoints).
  const [mailboxDomainKey, setMailboxDomainKey] = useState(null);
  const [orgLogo, setOrgLogo] = useState(null);
  const [dnsRecords, setDnsRecords] = useState([]);
  const [error, setError] = useState('');
  const navigate = useNavigate();
  const { refreshAccount, currentOrg } = useAuth();

  // Adding a domain to an org you already own (the console "Add domain" flow) must
  // NOT create a second org — it adds a domain to the current org. Only the very
  // first connect (no org yet) creates the org via POST /orgs.
  const handleAddDomain = async (e) => {
    e.preventDefault();
    setError('');
    try {
      if (currentOrg) {
        const data = await api.addDomain(currentOrg.id, domain);
        setOrgId(currentOrg.id);
        // The serialized public id is `id` (holds the model's prefixed-nanoid
        // `key`); there is no `key` field on the response.
        setDomainKey(data.domain.id);
        setMailboxDomainKey(data.domain.id);
        setOrgLogo(currentOrg.logo_url || null);
        await refreshAccount();
        const dns = await api.getDomainDns(currentOrg.id, data.domain.id);
        setDnsRecords(dns.records || []);
      } else {
        const data = await api.post('/orgs', { domain, name: domain });
        setOrgId(data.organization.id);
        setMailboxDomainKey(data.organization.domains?.[0]?.id || null);
        setOrgLogo(data.organization.logo_url || null);
        // Pull the new org into AuthProvider so /console reflects it without a reload.
        await refreshAccount();
        const dns = await api.getOrgDns(data.organization.id);
        setDnsRecords(dns.records || []);
      }
      setStep(1);
    } catch (err) {
      setError(err.message);
    }
  };

  // First-org signup lands in the inbox; adding a domain to an existing org
  // (domainKey set) goes back to the console where the domain list lives.
  const handleFinish = () => {
    navigate(domainKey ? consolePath() : `/#${orgId}`);
  };

  // Step back through the wizard; from the first step, back to the console.
  const goBack = () => (step === 0 ? navigate(consolePath()) : setStep((s) => s - 1));

  return (
    <ManagementLayout centered coBrandLogo={orgLogo} topRight={<span className={styles.step}>Step {step + 1} of {STEP_COUNT}</span>}>
      <MgmtCard className={`${styles.card} ${step === 1 || step === 2 ? styles.cardWide : ''}`}>
        <button type="button" className={styles.back} onClick={goBack}>
          <Icon name="chevron.left" size={13} /> {step === 0 ? 'Back to console' : 'Back'}
        </button>
        {/* Step 0: Connect domain */}
        {step === 0 && (
          <>
            <h1 className={styles.title}>Connect your domain</h1>
            <p className={styles.sub}>Its mail lands in the domain’s inbox, where your team sorts it together.</p>
            {error && <div className={styles.error} role="alert">{error}</div>}
            <form className={styles.form} onSubmit={handleAddDomain}>
              <MgmtField
                label="Your domain"
                value={domain}
                onChange={(e) => setDomain(e.target.value)}
                placeholder="yourcompany.com"
                required
                autoFocus
              />
              <MgmtButton type="submit" variant="primary" block>Add domain</MgmtButton>
            </form>
          </>
        )}

        {/* Step 1: DNS records + inline verify (shared with the console Verify modal) */}
        {step === 1 && (
          <>
            <h1 className={styles.title}>Verify {domain}</h1>
            <p className={styles.sub}>Add these records at your DNS provider, then verify. We keep checking on our own too.</p>
            <DnsVerify
              orgKey={orgId}
              domainKey={domainKey}
              records={dnsRecords}
              onVerified={() => setStep(2)}
            />
          </>
        )}

        {/* Step 2: Mailboxes — assign addresses on the new domain */}
        {step === 2 && (
          <MailboxStep
            orgKey={orgId}
            domainKey={mailboxDomainKey}
            domainName={domain}
            onDone={() => setStep(3)}
          />
        )}

        {/* Step 3: Test email */}
        {step === 3 && (
          <>
            <h1 className={styles.title}>You’re all set</h1>
            <p className={styles.sub}>Send an email to any address @{domain} and watch it land in the domain’s inbox.</p>
            <MgmtButton variant="primary" block onClick={handleFinish}>{domainKey ? 'Back to console' : 'Go to inbox'}</MgmtButton>
          </>
        )}
      </MgmtCard>
    </ManagementLayout>
  );
}
