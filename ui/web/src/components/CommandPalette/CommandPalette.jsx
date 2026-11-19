import { useState, useEffect, useRef, useMemo, useCallback, useContext } from 'react';
import { useNavigate, useParams } from 'react-router';
import Modal from '../Modal/Modal';
import Icon from '../Icon';
import useTheme from '../../hooks/useTheme';
import useDevMode from '../../hooks/useDevMode';
import { AuthContext } from '../../hooks/AuthProvider';
import { focusGlobalSearch } from '../../lib/globalSearch';
import { highlightRuns } from '../../lib/fuzzy';
import { GROUP, RECENT_LIMIT, readRecent, writeRecent, buildSections } from './paletteModel';
import { shortcutHint } from '../../lib/shortcuts';
import { isTauri } from '../../lib/tauri';
import { isRealOrgId } from '../../lib/org';
import { isDemoMode, toggleDemoMode } from '../../lib/demoData';
import usePlannerStore from '../../stores/plannerStore';
import { emitDemoMail, emitDemoMailBurst, emitDemoOtpCode, emitDemoSignInLink, emitDemoSocial, emitDemoMeeting, emitDemoInvite } from '../../lib/demoNotifications';
import styles from './CommandPalette.module.css';

// Build the full, context-aware command list.
//   - Navigation commands are org-aware (fall back to the non-org route when possible).
//   - Global commands (theme, search) work on any page.
//   - Page-specific commands (compose, view toggle, …) come in via `actions`; entries
//     whose handler is absent are filtered out, so each page only shows what it supports.
function buildCommands({ org, navigate, mode, toggleTheme, actions, devMode }) {
  const base = org ? `/${org}` : '';
  const demo = isDemoMode();
  const commands = [
    { id: 'inbox', group: GROUP.GO, icon: 'tray.fill', keywords: 'mail messages home unified', label: 'Go to Inbox', shortcut: 'G I', run: () => navigate(org ? `/${org}/mail` : '/mail') },
    org && { id: 'command-center', group: GROUP.GO, icon: 'point.connected', keywords: 'graph network explorer overview map', label: 'Open Command Center', run: () => navigate(`/${org}`) },
    org && { id: 'calendar', group: GROUP.GO, icon: 'calendar', keywords: 'events schedule meetings agenda', label: 'Go to Calendar', run: () => navigate(`/${org}/calendar`) },
    { id: 'settings', group: GROUP.GO, icon: 'gear', keywords: 'preferences options account configuration profile', label: 'Settings', shortcut: 'G S', run: () => navigate(`${base}/settings`) },
    { id: 'onboarding', group: GROUP.GO, icon: 'at.badge.plus', keywords: 'domain setup connect add account mailbox', label: 'Add a domain', run: () => navigate('/onboarding') },

    { id: 'search', group: GROUP.ACTION, icon: 'magnifyingglass', keywords: 'find filter query lookup', label: 'Search conversations', shortcut: shortcutHint('search_focus'), run: () => focusGlobalSearch() },
    actions?.compose && { id: 'compose', group: GROUP.ACTION, icon: 'square.and.pencil', keywords: 'new write email draft send', label: 'Compose new message', shortcut: 'C', run: actions.compose },
    actions?.refresh && { id: 'refresh', group: GROUP.ACTION, icon: 'arrow.clockwise', keywords: 'sync reload update channels fetch', label: 'Resync all channels', shortcut: shortcutHint('sync'), run: actions.refresh },
    { id: 'timezone-planner', group: GROUP.ACTION, icon: 'globe', keywords: 'timezone time zone world clock meeting overlap utc gmt cest est plan', label: 'Open time zone planner', run: () => usePlannerStore.getState().openPlanner() },
    actions?.notifications && { id: 'notifications', group: GROUP.ACTION, icon: 'bell', keywords: 'alerts bell activity', label: 'Open notifications', run: actions.notifications },

    actions?.toggleView && { id: 'view', group: GROUP.VIEW, icon: 'square.grid.2x2', keywords: 'layout grid list columns density', label: 'Toggle list / grid view', shortcut: shortcutHint('view_toggle'), run: actions.toggleView },
    actions?.toggleUnread && { id: 'unread', group: GROUP.VIEW, icon: 'envelope.badge', keywords: 'filter unread inbox zero', label: 'Toggle unread-only filter', shortcut: shortcutHint('unread_toggle'), run: actions.toggleUnread },
    { id: 'theme', group: GROUP.VIEW, icon: mode === 'dark' ? 'sun.max.fill' : 'moon.fill', keywords: 'dark light appearance mode colours colors', label: mode === 'dark' ? 'Switch to light mode' : 'Switch to dark mode', run: toggleTheme },

    // Demo mode: every name, address, subject and body on screen is swapped for
    // a fictional stand-in (lib/demoData.js) — for screenshots and live demos.
    // Off again on the next toggle, and always off when the window is closed.
    { id: 'demo', group: GROUP.APP, icon: 'eye.slash', keywords: 'fake screenshot presentation anonymise anonymize sample', label: demo ? 'Turn demo data off' : 'Turn demo data on', shortcut: shortcutHint('demo'), run: toggleDemoMode },
    // On-demand alerts, so a demo can show a notification land on cue.
    demo && { id: 'demo-mail', group: GROUP.APP, icon: 'bell', keywords: 'notification alert fake trigger test', label: 'Demo: new email alert', run: emitDemoMail },
    demo && { id: 'demo-mail-burst', group: GROUP.APP, icon: 'bell', keywords: 'notification alert fake trigger test several multiple stack', label: 'Demo: several email alerts', run: () => emitDemoMailBurst(3) },
    demo && { id: 'demo-otp-code', group: GROUP.APP, icon: 'lock', keywords: 'notification alert otp code 2fa verification sign in login', label: 'Demo: sign-in code (OTP)', run: emitDemoOtpCode },
    demo && { id: 'demo-otp-link', group: GROUP.APP, icon: 'lock', keywords: 'notification alert magic link sign in login', label: 'Demo: sign-in link', run: emitDemoSignInLink },
    demo && { id: 'demo-social', group: GROUP.APP, icon: 'bubble.left.fill', keywords: 'notification alert whatsapp social chat message', label: 'Demo: new WhatsApp message', run: emitDemoSocial },
    demo && { id: 'demo-meeting', group: GROUP.APP, icon: 'calendar.badge.clock', keywords: 'notification alert reminder upcoming trigger', label: 'Demo: meeting starting soon', run: emitDemoMeeting },
    demo && { id: 'demo-invite', group: GROUP.APP, icon: 'envelope.badge', keywords: 'notification alert rsvp invitation trigger', label: 'Demo: meeting invitation', run: emitDemoInvite },

    // Desktop + dev mode only (toggle with `): the AI triage scoring harness.
    isTauri() && devMode && { id: 'triage-lab', group: GROUP.APP, icon: 'brain', keywords: 'ai eval scoring model prompt lab', label: 'Open Triage Lab', run: () => navigate('/triage-lab') },
  ];
  return commands.filter(Boolean);
}

export default function CommandPalette({ open, onClose, actions }) {
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const [recent, setRecent] = useState(readRecent);
  const inputRef = useRef(null);
  const listRef = useRef(null);
  // Last real pointer position — see handleRowHover.
  const pointer = useRef({ x: -1, y: -1 });
  const navigate = useNavigate();
  const { orgSlug } = useParams();
  const { mode, toggleTheme } = useTheme();
  const devMode = useDevMode();
  // Read straight from the context, not useAuth(): the palette also renders in
  // Storybook, outside any AuthProvider, where useAuth() throws.
  const currentOrgSlug = useContext(AuthContext)?.currentOrgSlug;

  // A non-real slug ("null"/"undefined") is org-less — don't build /null/... routes.
  // The palette is mounted above the route tree, so useParams only has a slug on
  // the pages that render it themselves; the signed-in org is the fallback, and
  // keeps the org-aware entries working on Settings, the console and Triage Lab.
  const org = isRealOrgId(orgSlug) ? orgSlug : (isRealOrgId(currentOrgSlug) ? currentOrgSlug : null);

  const commands = useMemo(
    () => buildCommands({ org, navigate, mode, toggleTheme, actions, devMode }),
    [org, navigate, mode, toggleTheme, actions, devMode]
  );

  // Shown only when nothing matches: run the typed text as a conversation search
  // (same route the ChromeBar search box navigates to on Enter).
  const searchFallback = useMemo(() => {
    const q = query.trim();
    if (!q) return null;
    return {
      id: 'search-query',
      icon: 'magnifyingglass',
      transient: true, // query-specific — never worth remembering as a recent
      label: `Search conversations for \u201c${q}\u201d`,
      run: () => navigate(`${org ? `/${org}` : '/mail'}/search?q=${encodeURIComponent(q)}`),
    };
  }, [query, org, navigate]);

  const sections = useMemo(
    () => buildSections(commands, query, recent, searchFallback),
    [commands, query, recent, searchFallback]
  );
  const flat = useMemo(() => sections.flatMap(s => s.items), [sections]);

  // Focus input when the palette opens; reset query, selection and recents each time.
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: reset palette state on open */
  useEffect(() => {
    if (!open) return;
    setQuery('');
    setActiveIndex(0);
    setRecent(readRecent());
    const timer = setTimeout(() => inputRef.current?.focus(), 50);
    return () => clearTimeout(timer);
  }, [open]);

  // Typing re-ranks the list, so the highlight goes back to the (new) best match.
  useEffect(() => { setActiveIndex(0); }, [query]);
  /* eslint-enable react-hooks/set-state-in-effect */

  // Keep the highlighted row visible when arrowing past the scroll viewport.
  useEffect(() => {
    listRef.current?.querySelector('[data-active="true"]')?.scrollIntoView({ block: 'nearest' });
  }, [activeIndex, sections]);

  // ⌘P closing the palette again is the global toggle's job (routes.jsx) — a
  // second listener here would close and reopen it in the same keystroke.
  // Escape is handled by <Modal> (capture-phase).

  const handleSelect = useCallback((cmd) => {
    if (!cmd) return;
    if (!cmd.transient) {
      const next = [cmd.id, ...recent.filter(id => id !== cmd.id)].slice(0, RECENT_LIMIT);
      setRecent(next);
      writeRecent(next);
    }
    cmd.run?.();
    onClose();
  }, [recent, onClose]);

  // Hover selects a row, but scrolling the list under a STATIONARY cursor also
  // fires mousemove on whatever row slid under it — so arrowing down past the
  // viewport moved the highlight one row and the hover immediately snapped it
  // back, and the list could never be arrowed to the end. Only a pointer that
  // actually moved counts.
  const handleRowHover = (e, index) => {
    if (e.screenX === pointer.current.x && e.screenY === pointer.current.y) return;
    pointer.current = { x: e.screenX, y: e.screenY };
    setActiveIndex(index);
  };

  const handleInputKeyDown = (e) => {
    const last = flat.length - 1;
    const move = (next) => {
      e.preventDefault();
      setActiveIndex(flat.length ? next : 0);
    };
    if (e.key === 'ArrowDown') move((activeIndex + 1) % flat.length);
    else if (e.key === 'ArrowUp') move((activeIndex - 1 + flat.length) % flat.length);
    else if (e.key === 'Home') move(0);
    else if (e.key === 'End') move(last);
    else if (e.key === 'Enter') {
      e.preventDefault();
      handleSelect(flat[activeIndex]);
    }
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      showClose={false}
      overlayClassName={styles.overlay}
      className={styles.palette}
    >
      <div className={styles.inputRow}>
        <Icon name="magnifyingglass" size={16} className={styles.inputIcon} />
        <input
          ref={inputRef}
          className={styles.input}
          placeholder="Type a command..."
          value={query}
          onChange={e => setQuery(e.target.value)}
          onKeyDown={handleInputKeyDown}
          role="combobox"
          aria-expanded
          aria-controls="palette-results"
          aria-activedescendant={flat.length ? `palette-cmd-${activeIndex}` : undefined}
          aria-label="Command palette"
          autoComplete="off"
          spellCheck="false"
        />
      </div>
      <div className={styles.results} id="palette-results" role="listbox" aria-label="Commands" ref={listRef}>
        {sections.map(section => (
          <div key={section.title ?? 'results'} className={styles.section}>
            {section.title && <div className={styles.sectionTitle}>{section.title}</div>}
            {section.items.map(cmd => (
              <button
                key={cmd.id}
                id={`palette-cmd-${cmd.index}`}
                role="option"
                aria-selected={cmd.index === activeIndex}
                data-active={cmd.index === activeIndex}
                className={`${styles.item}${cmd.index === activeIndex ? ` ${styles.itemActive}` : ''}`}
                onClick={() => handleSelect(cmd)}
                onMouseMove={(e) => handleRowHover(e, cmd.index)}
              >
                <Icon name={cmd.icon} size={16} className={styles.itemIcon} />
                <span className={styles.itemLabel}>
                  {highlightRuns(cmd.label, cmd.indices).map((run, i) =>
                    run.hit
                      ? <mark key={i} className={styles.hit}>{run.text}</mark>
                      : <span key={i}>{run.text}</span>
                  )}
                </span>
                {cmd.shortcut && <span className={styles.itemShortcut}>{cmd.shortcut}</span>}
              </button>
            ))}
          </div>
        ))}
        {flat.length === 0 && (
          <div className={styles.empty}>No matching commands</div>
        )}
      </div>
      <div className={styles.footer}>
        <span><kbd>↑</kbd><kbd>↓</kbd> navigate</span>
        <span><kbd>↵</kbd> run</span>
        <span><kbd>esc</kbd> close</span>
      </div>
    </Modal>
  );
}
