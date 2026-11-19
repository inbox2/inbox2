import { describe, it, expect } from 'vitest';
import { matchBackends, createGenerativeProvider } from '../matching';

describe('Progressive Matching', () => {
  describe('matchBackends', () => {
    it('enables classification on every capable device', () => {
      const decision = matchBackends({
        classificationBackend: 'wasm',
        generativeBackend: 'none',
        isDesktop: false,
        hasWebGPU: false,
        hasAppleFoundationModels: false,
        deviceMemory: 2,
      });

      expect(decision.classificationEnabled).toBe(true);
      expect(decision.classificationBackend).toBe('wasm');
    });

    it('maps tauri-ort classification backend with correct reasoning', () => {
      const decision = matchBackends({
        classificationBackend: 'tauri-ort',
        generativeBackend: 'tauri-native',
        isDesktop: true,
        hasWebGPU: true,
        hasAppleFoundationModels: false,
        deviceMemory: 16,
      });

      expect(decision.classificationBackend).toBe('tauri-ort');
      expect(decision.classificationReason).toContain('natively');
    });

    it('maps webgpu classification backend with correct reasoning', () => {
      const decision = matchBackends({
        classificationBackend: 'webgpu',
        generativeBackend: 'webgpu-webllm',
        isDesktop: false,
        hasWebGPU: true,
        hasAppleFoundationModels: false,
        deviceMemory: 8,
      });

      expect(decision.classificationBackend).toBe('webgpu');
      expect(decision.classificationReason).toContain('graphics chip');
    });

    it('maps wasm classification backend with correct reasoning', () => {
      const decision = matchBackends({
        classificationBackend: 'wasm',
        generativeBackend: 'none',
        isDesktop: false,
        hasWebGPU: false,
        hasAppleFoundationModels: false,
        deviceMemory: 4,
      });

      expect(decision.classificationBackend).toBe('wasm');
      expect(decision.classificationReason).toContain('processor');
    });

    it('maps apple-foundation-models generative with correct reasoning', () => {
      const decision = matchBackends({
        classificationBackend: 'tauri-ort',
        generativeBackend: 'apple-foundation-models',
        isDesktop: true,
        hasWebGPU: true,
        hasAppleFoundationModels: true,
        deviceMemory: 16,
      });

      expect(decision.generativeEnabled).toBe(true);
      expect(decision.generativeBackend).toBe('apple-foundation-models');
      expect(decision.generativeReason).toContain('Apple');
    });

    it('maps tauri-native generative with correct reasoning', () => {
      const decision = matchBackends({
        classificationBackend: 'tauri-ort',
        generativeBackend: 'tauri-native',
        isDesktop: true,
        hasWebGPU: true,
        hasAppleFoundationModels: false,
        deviceMemory: 16,
      });

      expect(decision.generativeEnabled).toBe(true);
      expect(decision.generativeBackend).toBe('tauri-native');
      expect(decision.generativeReason).toContain('download');
    });

    it('maps webgpu-webllm generative with memory info in reasoning', () => {
      const decision = matchBackends({
        classificationBackend: 'webgpu',
        generativeBackend: 'webgpu-webllm',
        isDesktop: false,
        hasWebGPU: true,
        hasAppleFoundationModels: false,
        deviceMemory: 8,
      });

      expect(decision.generativeEnabled).toBe(true);
      expect(decision.generativeBackend).toBe('webgpu-webllm');
      expect(decision.generativeReason).toContain('8');
    });

    it('maps none generative with helpful reasoning for no WebGPU', () => {
      const decision = matchBackends({
        classificationBackend: 'wasm',
        generativeBackend: 'none',
        isDesktop: false,
        hasWebGPU: false,
        hasAppleFoundationModels: false,
        deviceMemory: 4,
      });

      expect(decision.generativeEnabled).toBe(false);
      expect(decision.generativeBackend).toBe('none');
      expect(decision.generativeReason).toContain('This browser');
    });

    it('maps none generative with helpful reasoning for low memory', () => {
      const decision = matchBackends({
        classificationBackend: 'webgpu',
        generativeBackend: 'none',
        isDesktop: false,
        hasWebGPU: true,
        hasAppleFoundationModels: false,
        deviceMemory: 2,
      });

      expect(decision.generativeEnabled).toBe(false);
      expect(decision.generativeReason).toContain('memory');
    });
  });

  describe('createGenerativeProvider (Tier B scaffold)', () => {
    it('returns null for apple-foundation-models (not yet implemented)', () => {
      expect(createGenerativeProvider('apple-foundation-models')).toBeNull();
    });

    it('returns null for tauri-native (not yet implemented)', () => {
      expect(createGenerativeProvider('tauri-native')).toBeNull();
    });

    it('returns null for webgpu-webllm (not yet implemented)', () => {
      expect(createGenerativeProvider('webgpu-webllm')).toBeNull();
    });

    it('returns null for none', () => {
      expect(createGenerativeProvider('none')).toBeNull();
    });
  });
});
