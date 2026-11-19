import { useState, useEffect, useCallback } from 'react';
import Icon from '../Icon';
import Switch from '../Switch/Switch';
import { isTauri } from '../../lib/tauri';
import {
  detectLocalAgents,
  setLocalAgentEnabled,
  listFailedAgentRuns,
  retryAgentRun,
} from '../../lib/localAgents';
import { formatClock as shortTime } from '../../lib/relativeTime';
import styles from './LocalAgentsCard.module.css';

/**
 * Settings card: detect locally-installed CLI agents and toggle them on/off.
 * Desktop-only. See docs/Agentic-Filters.md §5.2.
 */
export default function LocalAgentsCard() {
  const [agents, setAgents] = useState([]);
  const [failures, setFailures] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const [list, failed] = await Promise.all([detectLocalAgents(), listFailedAgentRuns(20)]);
      setAgents(list || []);
      setFailures(failed || []);
    } catch (e) {
      setError(String(e?.message || e));
    } finally {
      setLoading(false);
    }
  }, []);

  const handleRetry = async (runKey) => {
    await retryAgentRun(runKey);
    setFailures((prev) => prev.filter((r) => r.key !== runKey));
  };

  /* eslint-disable react-hooks/set-state-in-effect -- intentional: detect agents on mount */
  useEffect(() => {
    if (isTauri()) refresh();
    else setLoading(false);
  }, [refresh]);
  /* eslint-enable react-hooks/set-state-in-effect */

  if (!isTauri()) return null;

  const toggle = async (agent) => {
    if (!agent.installed) return;
    const next = !agent.enabled;
    setAgents((prev) =>
      prev.map((a) => (a.adapter_id === agent.adapter_id ? { ...a, enabled: next } : a)),
    );
    await setLocalAgentEnabled(agent.adapter_id, next);
  };

  return (
    <>
      <div className={styles.header}>
        <p className={styles.intro}>
          Command-line agents your rules can run on new mail.
        </p>
        <button className={styles.refresh} onClick={refresh} aria-label="Re-scan">
          <Icon name="arrow.clockwise" size={12} />
        </button>
      </div>

      {loading ? (
        <p className={styles.note}>Scanning…</p>
      ) : error ? (
        <p className={styles.note}>Couldn&apos;t scan for agents: {error}</p>
      ) : (
        <div className={styles.list}>
          {agents.map((a) => (
            <div key={a.adapter_id} className={styles.row}>
              <div className={styles.info}>
                <span className={styles.name}>{a.display_name}</span>
                {a.installed ? (
                  <span className={styles.version}>{a.version || 'installed'}</span>
                ) : (
                  <a
                    className={styles.installLink}
                    href={a.install_url}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    Not installed. Get it
                  </a>
                )}
              </div>
              <Switch
                id={`agent-${a.adapter_id}`}
                checked={a.enabled}
                disabled={!a.installed}
                ariaLabel={`Enable ${a.display_name}`}
                onChange={() => toggle(a)}
              />
            </div>
          ))}
        </div>
      )}

      {failures.length > 0 && (
        <div className={styles.failures}>
          <div className={styles.failHeader}>
            <Icon name="exclamationmark.triangle" size={12} />
            <span>Failed runs</span>
          </div>
          {failures.map((r) => (
            <div key={r.key} className={styles.failRow}>
              <div className={styles.failInfo}>
                <span className={styles.failAgent}>{r.adapter_id}</span>
                <span className={styles.failErr}>{r.error || r.status}</span>
              </div>
              <span className={styles.failTime}>{shortTime(r.updated_at)}</span>
              <button className={styles.failRetry} onClick={() => handleRetry(r.key)}>
                Retry
              </button>
            </div>
          ))}
        </div>
      )}
    </>
  );
}
