import { useState, useEffect, useCallback } from 'react';
import Icon from '../Icon';
import Switch from '../Switch/Switch';
import SegmentedControl from '../SegmentedControl';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import relativeTime from '../../lib/relativeTime';
import { isTauri } from '../../lib/tauri';
import { getMcpInfo, setMcpEnabled, setMcpAgentAccess, ACCESS_LEVELS } from '../../lib/mcp';
import styles from './McpConnectCard.module.css';

const MASK = '••••••••';

/**
 * Settings card: let AI agents (Claude Code, Cursor, …) use this inbox through
 * the in-core MCP server, show how to connect them, and set each one's access.
 * Desktop-only. See docs/Vector-MCP.md.
 */
export default function McpConnectCard() {
  const [info, setInfo] = useState(null);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      setInfo(await getMcpInfo());
      setError('');
    } catch (e) {
      setError(String(e?.message || e));
    }
  }, []);

  /* eslint-disable react-hooks/set-state-in-effect -- intentional: load on mount */
  useEffect(() => {
    if (isTauri()) load();
  }, [load]);
  /* eslint-enable react-hooks/set-state-in-effect */

  if (!isTauri()) return null;
  if (error) return <p className={styles.note}>Couldn&apos;t load agent settings.</p>;
  if (!info) return null;

  const toggle = async () => {
    try {
      setInfo(await setMcpEnabled(!info.enabled));
    } catch (e) {
      setError(String(e?.message || e));
    }
  };

  const changeAccess = async (agent, level) => {
    setInfo((prev) => ({
      ...prev,
      agents: prev.agents.map((a) => (a.key === agent.key ? { ...a, permission_level: level } : a)),
    }));
    try {
      await setMcpAgentAccess(agent.key, level);
    } catch {
      load();
    }
  };

  const claudeCommand = (token) =>
    `claude mcp add --scope user --transport http inbox2 ${info.url} --header "Authorization: Bearer ${token}"`;
  const jsonConfig = (token) =>
    JSON.stringify(
      { mcpServers: { inbox2: { url: info.url, headers: { Authorization: `Bearer ${token}` } } } },
      null,
      2,
    );

  return (
    <>
      <p className={styles.intro}>Let apps like Claude Code read and act on your mail.</p>

      <div className={styles.toggleRow}>
        <Switch id="mcp-enabled" label="Allow agent connections" checked={info.enabled} onChange={toggle} />
      </div>

      {!info.enabled ? (
        <p className={styles.note}>Agents can&apos;t connect while this is off.</p>
      ) : (
        <>
          <CopyBlock
            title="Claude Code"
            helper="Paste this in your terminal."
            shown={claudeCommand(MASK)}
            value={claudeCommand(info.token)}
          />
          <CopyBlock
            title="Other apps"
            helper="Add this to the app's MCP settings."
            shown={jsonConfig(MASK)}
            value={jsonConfig(info.token)}
          />
          <p className={styles.warning}>
            <Icon name="lock.fill" size={11} />
            Anyone with this token can use your mail. Keep it private.
          </p>

          <div className={styles.sectionTitle}>Connected agents</div>
          {info.agents.length === 0 ? (
            <p className={styles.note}>Agents show up here once they connect.</p>
          ) : (
            <div className={styles.list}>
              {info.agents.map((a) => (
                <div key={a.key} className={styles.agent}>
                  <div className={styles.agentInfo}>
                    <span className={styles.agentName}>{a.name}</span>
                    {a.last_connected_at && (
                      <span className={styles.agentSeen}>Last used {relativeTime(a.last_connected_at)}</span>
                    )}
                  </div>
                  <SegmentedControl
                    options={ACCESS_LEVELS}
                    value={a.permission_level}
                    onChange={(level) => changeAccess(a, level)}
                    aria-label={`Access for ${a.name}`}
                  />
                </div>
              ))}
            </div>
          )}
          <p className={styles.note}>Full access can send and delete mail.</p>
        </>
      )}
    </>
  );
}

/** A command or config to paste elsewhere: shown with the token masked, copied whole. */
function CopyBlock({ title, helper, shown, value }) {
  const [copied, copy] = useCopyToClipboard();
  return (
    <div className={styles.block}>
      <div className={styles.blockHead}>
        <span className={styles.blockTitle}>{title}</span>
        <span className={styles.blockHelper}>{helper}</span>
      </div>
      <div className={styles.code}>
        <pre className={styles.codeText}>{shown}</pre>
        <button
          type="button"
          className={styles.copy}
          onClick={() => copy(value)}
          aria-label={`Copy ${title} setup`}
          title="Copy"
        >
          <Icon name={copied ? 'checkmark' : 'doc.on.doc'} size={13} />
        </button>
      </div>
    </div>
  );
}
