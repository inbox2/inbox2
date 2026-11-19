import { lazy, Suspense, useState } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router';
import useAuth from '../hooks/useAuth';
import Avatar from '../components/Avatar';
import Icon from '../components/Icon';
import { ALL_SECTIONS } from '../pages/settings/settingsSections';
import MobileShell, { MobileTopBar, MobileIconButton } from './MobileShell';
import { MOBILE_TAB, useMobileOrg } from './mobileContext';
import styles from './MobileMore.module.css';
import { consolePath } from '../lib/consoleHost';
import { isAdminRole } from '../lib/orgRoles';

const SettingsPage = lazy(() => import('../pages/settings/SettingsPage'));
const PasskeysModal = lazy(() => import('../pages/admin/PasskeysModal'));

// Web never shows the desktop-only sections (on-device AI, local rules, About).
const sectionsFor = (org, admin) => ALL_SECTIONS.filter((s) => !s.desktop && (!s.org || !!org?.id) && (!s.admin || admin)
  && (!s.mailClients || !!org?.mail_clients_enabled));

/* The More tab: who you're signed in as, the admin console (admins), passkeys,
 * every settings section, and sign out. A section opens /…/settings?section=key,
 * which renders that one settings panel full-width under a back bar. */
export default function MobileMore() {
  const [searchParams] = useSearchParams();
  const section = searchParams.get('section');
  return section ? <SettingsSection sectionKey={section} /> : <MoreMenu />;
}

function MoreMenu() {
  const navigate = useNavigate();
  const { user, isAdmin, logout } = useAuth();
  const { org, orgSlug } = useMobileOrg();
  const [passkeysOpen, setPasskeysOpen] = useState(false);
  const base = orgSlug ? `/${orgSlug}` : '';
  const sections = sectionsFor(org, isAdminRole(org?.role));
  const groups = [...new Set(sections.map((s) => s.group))];

  const row = (key, icon, label, onClick, { sub, tone } = {}) => (
    <button key={key} type="button" className={[styles.row, tone ? styles[tone] : ''].join(' ')} onClick={onClick}>
      <span className={styles.rowIcon}><Icon name={icon} size={16} /></span>
      <span className={styles.rowText}>
        <span className={styles.rowLabel}>{label}</span>
        {sub && <span className={styles.rowSub}>{sub}</span>}
      </span>
      {!tone && <Icon name="chevron.right" size={12} className={styles.chev} />}
    </button>
  );

  return (
    <MobileShell tab={MOBILE_TAB.MORE}>
      <MobileTopBar title="More" />
      <div className={styles.body}>
        <div className={styles.profile}>
          <Avatar name={user?.display_name || user?.username} email={user?.email} size={52} />
          <span className={styles.who}>
            <span className={styles.name}>{user?.display_name || user?.username}</span>
            <span className={styles.email}>{user?.email || org?.domain}</span>
          </span>
        </div>

        <div className={styles.card}>
          {isAdmin && row('admin', 'checkmark.shield.fill', 'Admin console', () => navigate(consolePath()),
            { sub: 'Domains, people, routing rules, billing' })}
          {orgSlug && row('disk', 'folder', 'Disk', () => navigate('/disk'), { sub: 'Files for you and your teams' })}
          {row('passkeys', 'key', 'Passkeys', () => setPasskeysOpen(true), { sub: 'Sign in with Face ID, Touch ID or a PIN' })}
          {row('apps', 'tray.and.arrow.down', 'Get the apps', () => navigate(consolePath('apps')))}
        </div>

        {groups.map((g) => (
          <section key={g}>
            <h2 className={styles.group}>{g}</h2>
            <div className={styles.card}>
              {sections.filter((s) => s.group === g).map((s) =>
                row(s.key, s.icon, s.label, () => navigate(`${base}/settings?section=${s.key}`, { state: { fromMore: true } })))}
            </div>
          </section>
        ))}

        <div className={styles.card}>
          {row('logout', 'rectangle.portrait.and.arrow.right', 'Sign out', async () => { await logout(); navigate('/login'); }, { tone: 'danger' })}
        </div>
      </div>

      {passkeysOpen && (
        <Suspense fallback={null}>
          <PasskeysModal onClose={() => setPasskeysOpen(false)} />
        </Suspense>
      )}
    </MobileShell>
  );
}

function SettingsSection({ sectionKey }) {
  const navigate = useNavigate();
  const { state } = useLocation();
  const label = ALL_SECTIONS.find((s) => s.key === sectionKey)?.label || 'Settings';
  // From the More menu, pop back to it; a deep link drops ?section= instead.
  const back = () => (state?.fromMore ? navigate(-1) : navigate({ search: '' }, { replace: true }));
  return (
    <MobileShell tab={MOBILE_TAB.MORE} hideNav>
      <MobileTopBar leading={<MobileIconButton icon="chevron.left" label="Back" onClick={back} />} title={label} />
      <Suspense fallback={null}>
        {/* Keyed: SettingsPage reads ?section= once, on mount. */}
        <SettingsPage key={sectionKey} />
      </Suspense>
    </MobileShell>
  );
}
