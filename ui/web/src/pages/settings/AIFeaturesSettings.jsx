import { useState, useEffect, useMemo } from 'react';
import Icon from '../../components/Icon';
import Switch from '../../components/Switch/Switch';
import AISetup from '../../components/AISetup';
import LocalAgentsCard from '../../components/LocalAgentsCard';
import McpConnectCard from '../../components/McpConnectCard';
import Button from '../../components/Button/Button';
import { isTauri } from '../../lib/tauri';
import {
  hasAIConsent,
  allModelsReady,
  getModelStatuses,
  getModelDiskUsage,
  removeAllModels,
  initializeInference,
  disposeInference,
  disposeGenerative,
} from '../../lib/ai';
import useModelLanes from '../../hooks/useModelLanes';
import AppleIntelligenceLogo from '../../components/AppleIntelligenceLogo';
import styles from './settings.module.css';
import aiStyles from './AIFeaturesSettings.module.css';

/**
 * The per-lane generation-engine picker — desktop parity with iOS's
 * BridgeVoicePanel: choose which engine writes summaries, smart replies, and
 * Bridge briefs (triage labels come from Jev). Lanes come from the core model manifest
 * (`model_lanes`), the free Qwen model downloads/deletes through the core
 * download manager, and the choice is applied live (`applyNluLane`).
 */
function GenerationEngineSection() {
  const {
    ready, pref, freeModel, hasKey,
    keyDraft, setKeyDraft, keyStatus, setKeyStatus, error,
    rows, variantRows,
    choose, chooseVariant, deleteVariant, saveKey,
  } = useModelLanes();

  if (!ready) return null;

  return (
    <div className={aiStyles.statusSection}>
      <p className={aiStyles.note}>
        Writes summaries, smart replies and Bridge briefs. Jev sets labels and urgency.
      </p>

      <div className={aiStyles.laneList} role="radiogroup" aria-label="Generation engine">
        {rows.map(r => (
          <div key={r.lane}>
            <button
              role="radio"
              aria-checked={pref === r.lane}
              className={`${aiStyles.laneRow} ${pref === r.lane ? aiStyles.laneRowActive : ''}`}
              onClick={() => choose(r.lane)}
              disabled={!r.enabled && pref !== r.lane}
            >
              <span className={aiStyles.laneRadio} aria-hidden="true">
                {pref === r.lane && <span className={aiStyles.laneRadioDot} />}
              </span>
              <span className={aiStyles.laneText}>
                <span className={aiStyles.laneName}>{r.name}</span>
                <span className={aiStyles.laneDesc}>{r.desc}</span>
              </span>
              {r.trailing}
            </button>
            {/* The free lane's model variants (Qwen ⇄ Gemma) — shown while the
                lane is selected; each row downloads/activates its model. */}
            {r.lane === 'free' && pref === 'free' && variantRows.length > 1 && (
              <div className={aiStyles.variantList} role="radiogroup" aria-label="Local model">
                {variantRows.map(v => (
                  <button
                    key={v.id}
                    role="radio"
                    aria-checked={freeModel === v.id}
                    className={`${aiStyles.laneRow} ${aiStyles.variantRow} ${freeModel === v.id ? aiStyles.laneRowActive : ''}`}
                    onClick={() => chooseVariant(v)}
                  >
                    <span className={aiStyles.laneRadio} aria-hidden="true">
                      {freeModel === v.id && <span className={aiStyles.laneRadioDot} />}
                    </span>
                    <span className={aiStyles.laneText}>
                      <span className={aiStyles.laneName}>{v.name}</span>
                      <span className={aiStyles.laneDesc}>{v.desc}</span>
                    </span>
                    {v.state === 'installed' && (
                      <span
                        className={aiStyles.laneIconBtn}
                        role="button"
                        tabIndex={0}
                        onClick={(e) => { e.stopPropagation(); deleteVariant(v.id); }}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            e.stopPropagation();
                            deleteVariant(v.id);
                          }
                        }}
                        aria-label={`Delete ${v.name}`}
                      >
                        <Icon name="trash" size={14} />
                      </span>
                    )}
                  </button>
                ))}
              </div>
            )}
          </div>
        ))}
      </div>

      {pref === 'openai' && (
        <>
          <div className={aiStyles.keyRow}>
            <input
              className={aiStyles.keyInput}
              type="password"
              placeholder={hasKey ? 'OpenAI key saved. Paste a new one to replace it' : 'OpenAI API key (sk-…)'}
              value={keyDraft}
              onChange={(e) => { setKeyDraft(e.target.value); setKeyStatus(''); }}
              aria-label="OpenAI API key"
            />
            <button className={aiStyles.setupBtn} onClick={saveKey} disabled={!keyDraft.trim()}>
              Save key
            </button>
          </div>
          {keyStatus && (
            <p className={`${aiStyles.note} ${keyStatus.endsWith('✓') ? aiStyles.keyOk : ''}`}>{keyStatus}</p>
          )}
        </>
      )}
      {error && <p className={`${aiStyles.note} ${aiStyles.laneError}`}>{error}</p>}
    </div>
  );
}

export default function AIFeaturesSettings() {
  const [enabled, setEnabled] = useState(hasAIConsent() && allModelsReady());
  const [showSetup, setShowSetup] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);
  const [diskUsage, setDiskUsage] = useState({ totalMB: 0, models: [] });
  const [removing, setRemoving] = useState(false);

  // refreshKey is an intentional invalidation trigger for this memoization
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const models = useMemo(() => getModelStatuses(), [refreshKey]);

  useEffect(() => {
    getModelDiskUsage().then(setDiskUsage);
  }, [refreshKey]);

  const handleToggle = async () => {
    if (enabled) {
      disposeInference();
      setEnabled(false);
    } else {
      if (allModelsReady()) {
        await initializeInference();
        setEnabled(true);
      } else {
        setShowSetup(true);
      }
    }
  };

  const handleRemoveModels = async () => {
    setRemoving(true);
    disposeInference();
    disposeGenerative();
    await removeAllModels();
    // Also reclaim the lane-managed free generation models (the GGUFs the
    // sidecar runs — every installed variant) — disposeGenerative stopped the
    // sidecar holding them.
    if (isTauri()) {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const variants = await invoke('free_model_variants', { capability: 'nlu' });
        for (const v of variants) {
          if (v.state === 'installed') await invoke('model_delete', { id: v.id });
        }
      } catch { /* best effort — the danger zone still cleared Tier A */ }
    }
    setEnabled(false);
    setRefreshKey(k => k + 1);
    setDiskUsage({ totalMB: 0, models: [] });
    setRemoving(false);
  };

  const handleSetupComplete = () => {
    setShowSetup(false);
    setRefreshKey(k => k + 1);
    setEnabled(hasAIConsent() && allModelsReady());
    if (allModelsReady()) {
      initializeInference();
    }
  };

  if (showSetup) {
    return (
      <section className={styles.settingsPanel}>
        <h1 className={styles.settingsTitle}>On-device AI</h1>
        <AISetup onComplete={handleSetupComplete} compact />
      </section>
    );
  }

  return (
    <div className={styles.prefGrid}>
      <section className={styles.settingsPanel}>
      <h1 className={styles.settingsTitle}>On-device AI</h1>

      <div className={styles.providerCard}>
        <div className={styles.providerHeader}>
          <AppleIntelligenceLogo size={28} />
          <div>
            <h3 className={styles.providerName}>Apple Intelligence</h3>
            <p className={styles.providerDesc}>Runs on this device. Your mail stays here.</p>
          </div>
        </div>
      </div>

      <div className={aiStyles.toggleRow}>
        <Switch
          id="ondevice-ai"
          label={
            <span className={aiStyles.toggleLabel}>
              <Icon name="bolt.fill" size={16} className={aiStyles.toggleIcon} />
              Enable on-device AI
            </span>
          }
          checked={enabled}
          onChange={handleToggle}
        />
      </div>

      {enabled && (
        <div className={aiStyles.statusSection}>
          <div className={aiStyles.statusHeader}>
            <Icon name="checkmark.circle.fill" size={14} className={aiStyles.statusOk} />
            <span>Models loaded and running</span>
          </div>

          <div className={aiStyles.modelList}>
            {models.map(m => (
              <div key={m.id} className={aiStyles.modelItem}>
                <span className={aiStyles.modelName}>{m.name}</span>
                <span className={aiStyles.modelSize}>{m.sizeMB} MB</span>
              </div>
            ))}
          </div>

          <div className={aiStyles.diskUsage}>
            Total disk usage: {diskUsage.totalMB} MB
          </div>
        </div>
      )}

      {!enabled && allModelsReady() && (
        <div className={aiStyles.actionsSection}>
          <p className={aiStyles.note}>
            Models are downloaded. Turn on AI above to use them.
          </p>
        </div>
      )}

      {allModelsReady() && (
        <div className={`${styles.settingsInnerCard} ${styles.settingsInnerCardDanger}`}>
          <div className={styles.settingsSectionTitle}>Danger zone</div>
          <div className={styles.dangerZoneRow}>
            <div>
              <span className={styles.tablePrimary}>Remove all AI models</span>
              <span className={styles.tableSecondary}>Deletes downloaded models to free up space.</span>
            </div>
            <Button
              variant="danger"
              className={styles.dangerZoneBtn}
              onClick={handleRemoveModels}
              disabled={removing}
            >
              {removing ? 'Removing…' : 'Remove all AI models'}
            </Button>
          </div>
        </div>
      )}

      </section>

      {/* Generation engine — its own card, right of On-device AI. */}
      <section className={styles.settingsPanel}>
        <h1 className={styles.settingsTitle}>Generation engine</h1>
        {enabled
          ? <GenerationEngineSection />
          : (
            <p className={aiStyles.note}>
              Turn on on-device AI to pick what writes summaries, smart replies and Bridge briefs.
            </p>
          )}
      </section>

      {/* Local agents is its own panel, distinct from the On-device AI panel
          (which owns the models + its danger zone above). Desktop-only. */}
      {isTauri() && (
        <section className={styles.settingsPanel}>
          <h1 className={styles.settingsTitle}>Local agents</h1>
          <LocalAgentsCard />
        </section>
      )}

      {/* Bottom right: apps that use this inbox through the MCP server. Desktop-only. */}
      {isTauri() && (
        <section className={styles.settingsPanel}>
          <h1 className={styles.settingsTitle}>Connect an AI agent</h1>
          <McpConnectCard />
        </section>
      )}
    </div>
  );
}
