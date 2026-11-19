import { describe, it, expect, beforeEach, vi } from 'vitest';

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

import {
  isGenerativeReady,
  getGenerativeBackend,
  disposeGenerative,
  generateSmartReplies,
  summarizeThread,
} from '../generative';

describe('Generative AI API (Tier B)', () => {
  beforeEach(async () => {
    localStorageMock.clear();
    await disposeGenerative();
  });

  describe('initial state', () => {
    it('isGenerativeReady returns false before initialization', () => {
      expect(isGenerativeReady()).toBe(false);
    });

    it('getGenerativeBackend returns "none" before initialization', () => {
      expect(getGenerativeBackend()).toBe('none');
    });
  });

  describe('graceful degradation', () => {
    it('generateSmartReplies returns empty array when not ready', async () => {
      const result = await generateSmartReplies('Hello, can you help?', 'John');
      expect(result).toEqual([]);
    });

    it('summarizeThread reports no summary and a reason when not ready', async () => {
      const result = await summarizeThread('Thread text here');
      expect(result.summary).toBeNull();
      expect(result.reason).toBeTruthy();
    });
  });

  describe('no network during inference without initialization', () => {
    it('does not make fetch calls when generating without init', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');

      await generateSmartReplies('Can you send me the report?', 'Alice');
      await summarizeThread('Important meeting notes...');

      expect(fetchSpy).not.toHaveBeenCalled();
      fetchSpy.mockRestore();
    });
  });

  describe('dispose', () => {
    it('disposeGenerative resets state', async () => {
      await disposeGenerative();
      expect(isGenerativeReady()).toBe(false);
      expect(getGenerativeBackend()).toBe('none');
    });
  });
});
