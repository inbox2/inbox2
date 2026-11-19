import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  hasAIConsent,
  setAIConsent,
  getModelStatuses,
  allModelsReady,
  removeAllModels,
} from '../modelManager';
import { MODEL_REGISTRY } from '../models';

// Mock localStorage
const localStorageMock = (() => {
  let store = {};
  return {
    getItem: (key) => store[key] ?? null,
    setItem: (key, value) => { store[key] = String(value); },
    removeItem: (key) => { delete store[key]; },
    clear: () => { store = {}; },
  };
})();

Object.defineProperty(globalThis, 'localStorage', { value: localStorageMock });

// Mock indexedDB
Object.defineProperty(globalThis, 'indexedDB', {
  value: {
    databases: vi.fn().mockResolvedValue([]),
    deleteDatabase: vi.fn(),
  },
});

describe('Model Manager', () => {
  beforeEach(() => {
    localStorageMock.clear();
  });

  describe('consent management', () => {
    it('returns false when no consent has been given', () => {
      expect(hasAIConsent()).toBe(false);
    });

    it('returns true after consent is granted', () => {
      setAIConsent(true);
      expect(hasAIConsent()).toBe(true);
    });

    it('returns false after consent is revoked', () => {
      setAIConsent(true);
      setAIConsent(false);
      expect(hasAIConsent()).toBe(false);
    });
  });

  describe('model status', () => {
    it('returns not_downloaded for all models initially', () => {
      const statuses = getModelStatuses();
      expect(statuses).toHaveLength(Object.keys(MODEL_REGISTRY).length);
      statuses.forEach(s => {
        expect(s.status).toBe('not_downloaded');
        expect(s.progress).toBe(0);
      });
    });

    it('returns ready for models with stored metadata', () => {
      const metadata = {
        sentiment: { version: 'int8', downloadedAt: '2025-01-01' },
        intent: { version: 'int8', downloadedAt: '2025-01-01' },
        embeddings: { version: 'int8', downloadedAt: '2025-01-01' },
      };
      localStorageMock.setItem('inbox2_ai_models', JSON.stringify(metadata));

      const statuses = getModelStatuses();
      statuses.forEach(s => {
        expect(s.status).toBe('ready');
        expect(s.progress).toBe(100);
      });
    });

    it('allModelsReady returns false when not all models are downloaded', () => {
      const metadata = {
        sentiment: { version: 'int8', downloadedAt: '2025-01-01' },
      };
      localStorageMock.setItem('inbox2_ai_models', JSON.stringify(metadata));

      expect(allModelsReady()).toBe(false);
    });

    it('allModelsReady returns true when all models are downloaded', () => {
      const metadata = {
        sentiment: { version: 'int8', downloadedAt: '2025-01-01' },
        intent: { version: 'int8', downloadedAt: '2025-01-01' },
        embeddings: { version: 'int8', downloadedAt: '2025-01-01' },
      };
      localStorageMock.setItem('inbox2_ai_models', JSON.stringify(metadata));

      expect(allModelsReady()).toBe(true);
    });
  });

  describe('model removal', () => {
    it('clears stored metadata and consent on removal', async () => {
      setAIConsent(true);
      const metadata = {
        sentiment: { version: 'int8', downloadedAt: '2025-01-01' },
        intent: { version: 'int8', downloadedAt: '2025-01-01' },
        embeddings: { version: 'int8', downloadedAt: '2025-01-01' },
      };
      localStorageMock.setItem('inbox2_ai_models', JSON.stringify(metadata));

      await removeAllModels();

      expect(hasAIConsent()).toBe(false);
      expect(allModelsReady()).toBe(false);
    });
  });
});
