import { useState, useEffect } from 'react';
import api from '../../../lib/api';
import log from '../../../lib/log';
import Icon from '../../../components/Icon';
import styles from '../settings.module.css';

export default function RulesSettings({ orgId }) {
  const [rules, setRules] = useState([]);

  useEffect(() => {
    if (!orgId) return;
    api.get(`/orgs/${orgId}/rules`).then(data => setRules(data.rules))
      .catch(e => log.warn('Rules', `Failed to load rules: ${e?.message || e}`));
  }, [orgId]);

  const handleToggle = async (ruleId) => {
    await api.patch(`/orgs/${orgId}/rules/${ruleId}/toggle`);
    const data = await api.get(`/orgs/${orgId}/rules`);
    setRules(data.rules);
  };

  const handleDelete = async (ruleId) => {
    await api.delete(`/orgs/${orgId}/rules/${ruleId}`);
    setRules(rules.filter(r => r.id !== ruleId));
  };

  return (
    <>
      <h1 className={styles.settingsTitle}>Routing rules</h1>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Rules ({rules.length})</div>
        {rules.length === 0 ? (
          <p className={styles.tableEmpty}>No routing rules configured yet.</p>
        ) : (
          <table className={styles.settingsTable}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rules.map(rule => (
                <tr key={rule.id}>
                  <td><span className={styles.tablePrimary}>{rule.name}</span></td>
                  <td>
                    <span className={styles.tableBadge} data-status={rule.enabled ? 'active' : 'disabled'}>
                      {rule.enabled ? 'active' : 'disabled'}
                    </span>
                  </td>
                  <td className={styles.tableActions}>
                    <button
                      className={styles.tableAction}
                      onClick={() => handleToggle(rule.id)}
                      title={rule.enabled ? 'Disable rule' : 'Enable rule'}
                    >
                      <Icon name={rule.enabled ? 'minus.circle' : 'checkmark.circle'} size={14} />
                    </button>
                    <button className={styles.tableAction} onClick={() => handleDelete(rule.id)} title="Delete rule">
                      <Icon name="trash" size={14} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
