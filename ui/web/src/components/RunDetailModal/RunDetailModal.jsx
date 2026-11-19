import { useState } from 'react';
import Modal from '../Modal/Modal';
import Icon from '../Icon';
import AgentLogo from '../AgentLogo/AgentLogo';
import styles from './RunDetailModal.module.css';

const STATUS_LABEL = {
  pending: 'Waiting',
  awaiting_approval: 'Needs approval',
  running: 'Running',
  succeeded: 'Succeeded',
  failed: 'Failed',
  timeout: 'Timed out',
};

// Parse result_json once into the bits the view needs: the agent's one-line
// `summary` and the pretty-printed whole (raw string if it isn't valid JSON).
function parseResult(raw) {
  if (!raw) return { summary: '', pretty: '' };
  try {
    const obj = JSON.parse(raw);
    return { summary: obj.summary || '', pretty: JSON.stringify(obj, null, 2) };
  } catch {
    return { summary: '', pretty: raw };
  }
}

const fmtTokens = (n) => (n == null ? null : n.toLocaleString());

// A key/value definition list from [label, value] tuples; renders nothing when empty.
function MetaList({ items }) {
  if (!items.length) return null;
  return (
    <dl className={styles.meta}>
      {items.map(([k, v]) => (
        <div key={k} className={styles.metaItem}>
          <dt className={styles.metaKey}>{k}</dt>
          <dd className={styles.metaVal}>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

/**
 * Read-only detail for a single agent run. Shows the agent's summary + headline
 * metrics by default; "Show details" expands the task and the full `result.json`
 * (the agent's `log` of what it did + structured `data`) in a monospace block.
 * Everything is already persisted in agent_runs, so this is purely a view.
 */
export default function RunDetailModal({ run, onClose, onRerun }) {
  const [expanded, setExpanded] = useState(false);
  if (!run) return null;

  const { summary, pretty: result } = parseResult(run.result_json);
  const tokens =
    run.input_tokens != null || run.output_tokens != null
      ? `${fmtTokens(run.input_tokens) ?? '–'} in / ${fmtTokens(run.output_tokens) ?? '–'} out`
      : null;
  const meta = [
    run.duration_ms != null && ['Duration', `${(run.duration_ms / 1000).toFixed(1)}s`],
    run.cost_usd != null && ['Cost', `$${run.cost_usd.toFixed(4)}`],
    tokens && ['Tokens', tokens],
  ].filter(Boolean);
  const extraMeta = [
    run.exit_code != null && ['Exit', String(run.exit_code)],
    run.attempts != null && ['Attempts', String(run.attempts)],
    run.finished_at && ['Finished', run.finished_at.replace('T', ' ').replace(/\..*$/, '')],
  ].filter(Boolean);

  // The agent's one-line summary is the headline once a run has produced one; until
  // then (a matched rule that hasn't run) the Task — the prompt it would run — is
  // the headline, shown up top instead of behind "Show details".
  const taskUpTop = !summary && !!run.task;
  const taskInDetails = !!summary && !!run.task;
  const hasDetails = !!result || taskInDetails || extraMeta.length > 0;
  // A persisted, finished run can be force-rerun — re-queues the same task.
  const canRerun = !!onRerun && !!run.key && ['succeeded', 'failed', 'timeout'].includes(run.status);

  return (
    <Modal open onClose={onClose} className={styles.panel}>
      <div className={styles.title}>
        <AgentLogo adapterId={run.adapter_id} size={17} />
        <span className={styles.adapter}>{run.adapter_id}</span>
        <span className={styles.status} data-status={run.status}>
          {STATUS_LABEL[run.status] || run.status}
        </span>
        {canRerun && (
          <button
            type="button"
            className={styles.rerun}
            onClick={() => onRerun(run.key)}
            aria-label="Run again"
            title="Run again"
          >
            <Icon name="play.fill" size={13} />
          </button>
        )}
      </div>

      <MetaList items={meta} />

      {summary && <p className={styles.summary}>{summary}</p>}

      {taskUpTop && (
        <>
          <div className={styles.section}>Prompt</div>
          <pre className={styles.code}>{run.task}</pre>
        </>
      )}

      {run.error && (
        <>
          <div className={styles.section}>Error</div>
          <pre className={`${styles.code} ${styles.codeError}`}>{run.error}</pre>
        </>
      )}

      {hasDetails && (
        <button type="button" className={styles.expand} onClick={() => setExpanded((e) => !e)}>
          <Icon name={expanded ? 'chevron.down' : 'chevron.right'} size={11} />
          {expanded ? 'Hide details' : 'Show details'}
        </button>
      )}

      {hasDetails && expanded && (
        <div className={styles.details}>
          <MetaList items={extraMeta} />

          {taskInDetails && (
            <>
              <div className={styles.section}>Prompt</div>
              <pre className={styles.code}>{run.task}</pre>
            </>
          )}

          {result && (
            <>
              <div className={styles.section}>Result</div>
              <pre className={styles.code}>{result}</pre>
            </>
          )}
        </div>
      )}
    </Modal>
  );
}
