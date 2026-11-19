import { describe, it, expect, beforeEach, vi } from 'vitest';

// Mock localStorage for Node environment
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

import { analyzeSentiment, classifyIntent, generateEmbedding, disposeInference } from '../inference';

// These tests validate the inference API contract without loading real models.
// Real model inference is tested via integration tests (requires model download).

describe('Inference API', () => {
  beforeEach(() => {
    disposeInference();
  });

  describe('input validation', () => {
    it('analyzeSentiment returns null for empty text', async () => {
      expect(await analyzeSentiment('')).toBeNull();
      expect(await analyzeSentiment(null)).toBeNull();
      expect(await analyzeSentiment('   ')).toBeNull();
    });

    it('classifyIntent returns null for empty text', async () => {
      expect(await classifyIntent('')).toBeNull();
      expect(await classifyIntent(null)).toBeNull();
      expect(await classifyIntent('   ')).toBeNull();
    });

    it('generateEmbedding returns null for empty text', async () => {
      expect(await generateEmbedding('')).toBeNull();
      expect(await generateEmbedding(null)).toBeNull();
      expect(await generateEmbedding('   ')).toBeNull();
    });
  });

  describe('graceful degradation without consent', () => {
    it('analyzeSentiment returns null when models not ready', async () => {
      // No consent given, no models downloaded
      const result = await analyzeSentiment('Hello world');
      expect(result).toBeNull();
    });

    it('classifyIntent returns null when models not ready', async () => {
      const result = await classifyIntent('Can you help me?');
      expect(result).toBeNull();
    });

    it('generateEmbedding returns null when models not ready', async () => {
      const result = await generateEmbedding('Some text');
      expect(result).toBeNull();
    });
  });

  describe('no network requests during inference', () => {
    it('does not make fetch calls when analyzing text without consent', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');

      await analyzeSentiment('Test email about a meeting tomorrow');
      await classifyIntent('Can you send me the report?');
      await generateEmbedding('Important project update');

      // No fetch calls should have been made since inference wasn't initialized
      expect(fetchSpy).not.toHaveBeenCalled();
      fetchSpy.mockRestore();
    });
  });
});
