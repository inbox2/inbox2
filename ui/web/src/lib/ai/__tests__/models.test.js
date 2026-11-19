import { describe, it, expect } from 'vitest';
import { MODEL_REGISTRY, getTierADownloadSizeMB } from '../models';

describe('Model Configuration', () => {
  it('defines three Tier A models: sentiment, intent, embeddings', () => {
    expect(MODEL_REGISTRY).toHaveProperty('sentiment');
    expect(MODEL_REGISTRY).toHaveProperty('intent');
    expect(MODEL_REGISTRY).toHaveProperty('embeddings');
    expect(Object.keys(MODEL_REGISTRY)).toHaveLength(3);
  });

  it('each model has required fields', () => {
    for (const [key, model] of Object.entries(MODEL_REGISTRY)) {
      expect(model.id, `${key}.id`).toBeTruthy();
      expect(model.name, `${key}.name`).toBeTruthy();
      expect(model.repo, `${key}.repo`).toBeTruthy();
      expect(model.task, `${key}.task`).toBeTruthy();
      expect(model.quantization, `${key}.quantization`).toBe('int8');
      expect(model.approxSizeMB, `${key}.approxSizeMB`).toBeGreaterThan(0);
    }
  });

  it('sentiment model has expected labels', () => {
    expect(MODEL_REGISTRY.sentiment.labels).toContain('POSITIVE');
    expect(MODEL_REGISTRY.sentiment.labels).toContain('NEGATIVE');
  });

  it('intent model has expected classification labels', () => {
    const expectedLabels = ['question', 'request', 'complaint', 'FYI', 'scheduling', 'other'];
    expect(MODEL_REGISTRY.intent.labels).toEqual(expectedLabels);
  });

  it('embeddings model declares dimensions', () => {
    expect(MODEL_REGISTRY.embeddings.dimensions).toBe(384);
  });

  it('getTierADownloadSizeMB sums all model sizes', () => {
    const expected = Object.values(MODEL_REGISTRY)
      .reduce((sum, m) => sum + m.approxSizeMB, 0);
    expect(getTierADownloadSizeMB()).toBe(expected);
  });

  it('total download size is within expected range (100-300 MB)', () => {
    const size = getTierADownloadSizeMB();
    expect(size).toBeGreaterThanOrEqual(100);
    expect(size).toBeLessThanOrEqual(300);
  });
});
