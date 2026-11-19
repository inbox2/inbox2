import useAuth from '../../../hooks/useAuth';
import useTriageLabels from '../../../hooks/useTriageLabels';
import TriageLabelsEditor from '../../../components/TriageLabelsEditor/TriageLabelsEditor';
import styles from '../settings.module.css';

/**
 * Settings › Triage labels (MX): the org's Jev action labels — the eight
 * built-ins plus the org's own. Every member sees them; admins edit
 * (the API enforces it). docs/Triage.md.
 */
export default function TriageLabelsSettings({ orgId }) {
  const { isAdmin } = useAuth();
  const { labels, create, update, remove } = useTriageLabels(orgId);

  return (
    <>
      <h1 className={styles.settingsTitle}>Triage labels</h1>
      <p className={styles.sectionDesc}>
        Jev puts one of these on every new thread in the domain&rsquo;s inbox. Describe what
        each label is for, and what it isn&rsquo;t, in plain words.
        {!isAdmin && ' Only admins can change them.'}
      </p>
      <TriageLabelsEditor labels={labels} readOnly={!isAdmin} onCreate={create} onUpdate={update} onRemove={remove} />
    </>
  );
}
