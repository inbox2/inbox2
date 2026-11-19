import Spinner from '../../components/Spinner';
import useAuth from '../../hooks/useAuth';
import useAdminData from '../../hooks/useAdminData';
import useBilling from '../../hooks/useBilling';
import DowngradeConfirmModal from './DowngradeConfirmModal';
import DataExportCard from './DataExportCard';
import { MgmtButton } from '../../components/management';
import { limitLabel, priceLabel } from '../../lib/format';
import styles from './console.module.css';

/* Billing view — the org's plan cards + self-service upgrade/downgrade.
 * Billing is org-scoped (the subscription belongs to the org); this shows the
 * active org's plan and its domains-per-plan quota. */
export default function ConsoleBilling() {
  const { organizations, currentOrg } = useAuth();
  const { domains, refresh } = useAdminData(organizations);

  const billingOrgId = currentOrg?.id || organizations?.[0]?.id;
  const {
    billing, plans, planBusy, downgrade, setDowngrade, subscribe,
    currentPlan, domainUsageText,
  } = useBilling(billingOrgId, domains.length, refresh);

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>
            Billing{currentOrg?.domain ? ` · ${currentOrg.domain} workspace` : ''}
          </div>
          <h1 className={styles.pageTitle}>Billing &amp; plan</h1>
          <p className={styles.pageSub}>
            {currentPlan
              ? <>You’re on <strong>{currentPlan.name}</strong>{domainUsageText ? `, ${domainUsageText}` : ''}{billing && !['free', 'active', 'trialing'].includes(billing.status) ? ` · ${billing.status}` : ''}.</>
              : 'Loading your plan…'}
          </p>
        </div>
      </div>

      {plans.length === 0 ? (
        <div className={`${styles.card} ${styles.cardLoading}`}><Spinner size={20} color="#2f7ad6" /></div>
      ) : (
        <div className={styles.planGrid}>
          {plans.map((plan) => {
            const current = currentPlan && plan.name === currentPlan.name;
            const upgrade = currentPlan && plan.price_cents > currentPlan.price_cents;
            const free = plan.price_cents === 0;
            return (
              <div key={plan.id} className={[styles.card, styles.planCard, current ? styles.planCurrent : ''].join(' ')}>
                <div className={styles.planHead}>
                  <span className={styles.planName}>{plan.name}</span>
                  {current && <span className={`${styles.pill} ${styles.pillOk}`}>Current</span>}
                </div>
                <div className={styles.planPrice}>
                  {priceLabel(plan.price_cents)}{!free && <span className={styles.planPer}>/mo</span>}
                </div>
                <ul className={styles.planFeatures}>
                  <li>{limitLabel(plan.max_domains, 'domain')}</li>
                  <li>{limitLabel(plan.max_collaborators, 'collaborator')}</li>
                  <li>{plan.max_message_size_mb}MB max message size</li>
                  <li data-off={!plan.spam_filter || undefined}>{plan.spam_filter ? 'Spam filter' : 'No spam filter'}</li>
                  <li data-off={!plan.e2ee || undefined}>{plan.e2ee ? 'End-to-end encryption' : 'No end-to-end encryption'}</li>
                </ul>
                <div className={styles.planFoot}>
                  {current ? (
                    <span className={styles.planYours}>Your current plan</span>
                  ) : (
                    <MgmtButton
                      variant={upgrade ? 'primary' : 'glass'}
                      block
                      onClick={() => subscribe(plan)}
                      disabled={planBusy === plan.id}
                    >
                      {planBusy === plan.id ? 'Working…' : upgrade ? `Upgrade for ${priceLabel(plan.price_cents)}/mo` : 'Downgrade'}
                    </MgmtButton>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      <DataExportCard orgId={billingOrgId} />

      {downgrade && (
        <DowngradeConfirmModal
          plan={downgrade.plan}
          impact={downgrade.impact}
          busy={planBusy === downgrade.plan.id}
          onCancel={() => setDowngrade(null)}
          onConfirm={() => subscribe(downgrade.plan, { acknowledge: true })}
        />
      )}
    </>
  );
}
