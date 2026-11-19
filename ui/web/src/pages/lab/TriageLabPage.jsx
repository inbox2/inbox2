import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../../components/Icon';
import Button from '../../components/Button/Button';
import { isTauri } from '../../lib/tauri';
import { getDb } from '../../lib/db';
import log from '../../lib/log';
import styles from './TriageLabPage.module.css';

/** Friendly titles for the prompt-template sections, in file order. */
const SECTION_TITLES = {
  chat: 'Chat voice replies',
  brief: 'Daily brief',
  tomorrow: 'Tomorrow preview',
  week: 'Week highlights',
  draft_reply: 'Draft reply',
  summary: 'Thread summary',
  openai: 'OpenAI model',
};

/**
 * Parse the prompts TOML into preview sections: each `[section]` heading plus
 * its `system = '''…'''` text (or the `[openai] chat_model`). Tolerant — a
 * half-edited file just previews fewer sections.
 */
function parsePromptSections(toml) {
  const heads = [...toml.matchAll(/^\[(\w+)\]\s*$/gm)];
  return heads.map((m, i) => {
    const chunk = toml.slice(m.index + m[0].length, heads[i + 1]?.index ?? toml.length);
    const tri = chunk.match(/'''\n?([^]*?)'''/);
    const model = chunk.match(/chat_model\s*=\s*"([^"]+)"/);
    return {
      key: m[1],
      text: tri ? tri[1].trim() : model ? `Chat model: ${model[1]}` : '',
    };
  }).filter(s => s.text);
}

/** Render prompt text with `{placeholder}` tokens highlighted. */
function PromptText({ text }) {
  const parts = text.split(/(\{\w+\})/g);
  return (
    <p className={styles.previewText}>
      {parts.map((p, i) =>
        /^\{\w+\}$/.test(p) ? <span key={i} className={styles.placeholder}>{p}</span> : p
      )}
    </p>
  );
}

/**
 * Triage Lab — the desktop scoring harness UI (dev tool, /triage-lab; palette
 * entry appears in dev mode only).
 *
 * Top left: the fixtures editor (test threads + expected labels), with a
 * type-to-search over your real mail to pull any conversation in as a case.
 * Top right: per-case verdicts (label + Jev priority) from the PRODUCTION
 * triage path — the rules, then Jev with the engine's key and labels. Bottom:
 * the prompt-template editor (summaries, Bridge — not triage, which is Jev's)
 * with a live rendered preview. The same fixtures run on iOS/Android via the
 * engine's `run_triage_eval` FFI.
 */
export default function TriageLabPage() {
  const navigate = useNavigate();
  const [fixtures, setFixtures] = useState('');
  const [prompts, setPrompts] = useState('');
  const [promptsOverride, setPromptsOverride] = useState(false);
  const [promptsDirty, setPromptsDirty] = useState(false);
  const [promptsError, setPromptsError] = useState(null);
  const [report, setReport] = useState(null);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState(null);
  const [search, setSearch] = useState('');
  const [hits, setHits] = useState([]);
  const searchSeq = useRef(0);

  const preview = useMemo(() => parsePromptSections(prompts), [prompts]);

  useEffect(() => {
    if (!isTauri()) return;
    (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        setFixtures(await invoke('triage_eval_fixtures'));
        const p = await invoke('prompts_get');
        setPrompts(p.text);
        setPromptsOverride(p.isOverride);
      } catch (e) {
        log.warn('TriageLab', `load failed: ${e?.message || e}`);
      }
    })();
  }, []);

  // Type-to-search over the local mail store (subject + sender), newest first.
  useEffect(() => {
    const q = search.trim();
    const seq = ++searchSeq.current;
    const t = setTimeout(async () => {
      if (q.length < 2) { setHits([]); return; }
      try {
        const db = await getDb();
        if (!db) return;
        const like = `%${q}%`;
        const rows = await db.select(
          `SELECT c.key, c.subject, c.updated_at,
                  (SELECT m.from_address FROM messages m
                   WHERE m.conversation_key = c.key ORDER BY m.created_at DESC LIMIT 1) AS from_address
           FROM conversations c
           WHERE c.subject LIKE $1
              OR EXISTS (SELECT 1 FROM messages m WHERE m.conversation_key = c.key AND m.from_address LIKE $1)
           ORDER BY c.updated_at DESC LIMIT 8`,
          [like],
        );
        if (seq === searchSeq.current) setHits(rows || []);
      } catch (e) {
        log.warn('TriageLab', `search failed: ${e?.message || e}`);
      }
    }, 200);
    return () => clearTimeout(t);
  }, [search]);

  /** Pull a real conversation in as a fixture case (expected left empty). */
  const addFromMail = useCallback(async (conversationKey) => {
    setError(null);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      const evalCase = await invoke('triage_eval_case', { conversationKey });
      setFixtures(prev => {
        try {
          const doc = JSON.parse(prev);
          const cases = Array.isArray(doc) ? doc : doc.cases;
          if (!Array.isArray(cases)) throw new Error('no cases array');
          cases.push(evalCase);
          return JSON.stringify(doc, null, 2);
        } catch {
          setError("The fixtures JSON doesn't parse. Fix it before adding a message.");
          return prev;
        }
      });
      setSearch('');
      setHits([]);
    } catch (e) {
      setError(String(e?.message || e));
    }
  }, []);

  const run = useCallback(async () => {
    setRunning(true);
    setError(null);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      setReport(await invoke('triage_eval', { fixturesJson: fixtures }));
    } catch (e) {
      setError(String(e?.message || e));
    } finally {
      setRunning(false);
    }
  }, [fixtures]);

  const savePrompts = useCallback(async () => {
    setPromptsError(null);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('prompts_set', { text: prompts });
      setPromptsOverride(true);
      setPromptsDirty(false);
    } catch (e) {
      setPromptsError(String(e?.message || e));
    }
  }, [prompts]);

  const resetPrompts = useCallback(async () => {
    setPromptsError(null);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('prompts_reset');
      const p = await invoke('prompts_get');
      setPrompts(p.text);
      setPromptsOverride(false);
      setPromptsDirty(false);
    } catch (e) {
      setPromptsError(String(e?.message || e));
    }
  }, []);

  const onEditorKeyDown = useCallback(
    (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault();
        run();
      }
    },
    [run],
  );

  /** Leave the lab: back where you came from, or the inbox on a direct open. */
  const close = useCallback(() => {
    if (window.history.length > 1) navigate(-1);
    else navigate('/mail');
  }, [navigate]);

  // Escape closes the lab (a dev overlay, not a destination).
  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        close();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [close]);

  if (!isTauri()) {
    return (
      <div className={styles.page}>
        <div className={styles.empty}>The Triage Lab runs in the desktop app.</div>
      </div>
    );
  }

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div className={styles.titleGroup}>
          <Icon name="testtube.2" size={16} />
          <h1 className={styles.title}>Triage Lab</h1>
          <span className={styles.subtitle}>
            scores fixtures through the production rules + Jev, with the key and labels from Settings
          </span>
        </div>
        <div className={styles.headerActions}>
          {report && (
            <span className={styles.scoreboard}>
              <span className={styles.scoreMain}>{report.correct}/{report.scored}</span>
              <span className={styles.scoreDetail}>
                {report.by_rules} rules · {report.by_model} Jev{report.errors > 0 ? ` · ${report.errors} errors` : ''}
              </span>
            </span>
          )}
          <Button onClick={run} disabled={running || !fixtures.trim()}>
            {running ? 'Running…' : 'Run (⌘↵)'}
          </Button>
          <Button variant="secondary" onClick={close} aria-label="Close Triage Lab (Escape)">
            Close
          </Button>
        </div>
      </header>

      {error && (
        <div className={styles.errorBanner}>
          <Icon name="exclamationmark.triangle" size={12} /> {error}
        </div>
      )}

      <div className={styles.columns}>
        <section className={styles.panel}>
          <div className={styles.panelHead}>
            <h2 className={styles.panelTitle}>Test messages</h2>
            <span className={styles.panelHint}>JSON: name, subject, expected, messages[]</span>
          </div>
          <div className={styles.searchWrap}>
            <Icon name="magnifyingglass" size={13} className={styles.searchIcon} />
            <input
              className={styles.searchInput}
              placeholder="Search your mail to add a real message as a test case…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              aria-label="Search mail for a test message"
            />
            {hits.length > 0 && (
              <div className={styles.searchResults}>
                {hits.map(h => (
                  <button key={h.key} className={styles.searchHit} onClick={() => addFromMail(h.key)}>
                    <span className={styles.hitSubject}>{h.subject || '(no subject)'}</span>
                    <span className={styles.hitMeta}>
                      {h.from_address || ''}{h.updated_at ? ` · ${new Date(h.updated_at).toLocaleDateString()}` : ''}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>
          <textarea
            className={styles.editor}
            value={fixtures}
            onChange={(e) => setFixtures(e.target.value)}
            onKeyDown={onEditorKeyDown}
            spellCheck={false}
            aria-label="Eval fixtures JSON"
          />
        </section>

        <section className={styles.panel}>
          <div className={styles.panelHead}>
            <h2 className={styles.panelTitle}>Results</h2>
          </div>
          <div className={styles.results}>
            {!report && <div className={styles.empty}>Run the fixtures to see how each thread scores.</div>}
            {report?.results.map((r) => (
              <article
                key={r.name}
                className={`${styles.result} ${
                  r.pass === true ? styles.pass : r.pass === false ? styles.fail : r.error ? styles.err : ''
                }`}
              >
                <div className={styles.resultTop}>
                  <span className={styles.resultMark}>
                    {r.pass === true ? 'PASS' : r.pass === false ? 'FAIL' : r.error ? 'ERR' : '—'}
                  </span>
                  <span className={styles.resultName}>{r.name}</span>
                  <span className={styles.resultSource}>{r.source}</span>
                </div>
                <div className={styles.resultLabels}>
                  {r.expected && <span>expected <strong>{r.expected}</strong></span>}
                  <span>got <strong>{r.predicted || '-'}</strong></span>
                  {r.priority != null && <span>priority <strong>{Number(r.priority).toFixed(1)}</strong></span>}
                  {r.signals && <span className={styles.resultSignals}>signals: {r.signals}</span>}
                </div>
                {r.short && <div className={styles.resultShort}>“{r.short}”</div>}
                {r.error && <div className={styles.resultError}>{r.error}</div>}
              </article>
            ))}
          </div>
        </section>
      </div>

      <section className={`${styles.panel} ${styles.promptsPanel}`}>
        <div className={styles.panelHead}>
          <h2 className={styles.panelTitle}>Prompt templates</h2>
          <span className={styles.panelHint}>
            {promptsOverride ? 'using your override (prompts.toml)' : 'using the built-in defaults'}
            {promptsDirty ? ' · unsaved changes' : ''}
          </span>
          <div className={styles.panelActions}>
            <Button variant="secondary" onClick={resetPrompts} disabled={!promptsOverride && !promptsDirty}>
              Reset to defaults
            </Button>
            <Button onClick={savePrompts} disabled={!promptsDirty}>
              Save &amp; apply
            </Button>
          </div>
        </div>
        {promptsError && (
          <div className={styles.errorBanner}>
            <Icon name="exclamationmark.triangle" size={12} /> {promptsError}
          </div>
        )}
        <div className={styles.promptsSplit}>
          <textarea
            className={styles.editor}
            value={prompts}
            onChange={(e) => {
              setPrompts(e.target.value);
              setPromptsDirty(true);
            }}
            spellCheck={false}
            aria-label="Prompt templates TOML"
          />
          <div className={styles.preview} aria-label="Prompt preview">
            {preview.map(s => (
              <div key={s.key} className={styles.previewSection}>
                <h3 className={styles.previewTitle}>{SECTION_TITLES[s.key] || s.key}</h3>
                <PromptText text={s.text} />
              </div>
            ))}
            {preview.length === 0 && <div className={styles.empty}>Nothing to preview yet.</div>}
          </div>
        </div>
      </section>
    </div>
  );
}
