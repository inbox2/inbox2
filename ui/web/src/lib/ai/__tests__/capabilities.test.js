import { describe, it, expect } from 'vitest';
import { detectCapabilitiesFromEnv } from '../capabilities';

describe('AI Capability Detection', () => {
  describe('detectCapabilitiesFromEnv', () => {
    it('returns wasm backend when no WebGPU and not Tauri', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: false,
        deviceMemory: 8,
        hardwareConcurrency: 4,
        isDesktop: false,
        hasAppleFoundationModels: false,
      });

      expect(caps.canRunClassification).toBe(true);
      expect(caps.classificationBackend).toBe('wasm');
      expect(caps.generativeBackend).toBe('none');
      expect(caps.canRunGenerative).toBe(false);
    });

    it('returns webgpu backend when WebGPU available in browser', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 8,
        hardwareConcurrency: 8,
        isDesktop: false,
        hasAppleFoundationModels: false,
      });

      expect(caps.classificationBackend).toBe('webgpu');
      expect(caps.canRunClassification).toBe(true);
    });

    it('returns tauri-ort backend on desktop', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 16,
        hardwareConcurrency: 10,
        isDesktop: true,
        hasAppleFoundationModels: false,
      });

      expect(caps.classificationBackend).toBe('tauri-ort');
      expect(caps.canRunClassification).toBe(true);
    });

    it('returns apple-foundation-models generative backend on macOS 26+ desktop', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 16,
        hardwareConcurrency: 10,
        isDesktop: true,
        hasAppleFoundationModels: true,
      });

      expect(caps.generativeBackend).toBe('apple-foundation-models');
      expect(caps.canRunGenerative).toBe(true);
      expect(caps.classificationBackend).toBe('tauri-ort');
    });

    it('returns tauri-native generative backend on desktop without Apple models', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 16,
        hardwareConcurrency: 10,
        isDesktop: true,
        hasAppleFoundationModels: false,
      });

      expect(caps.generativeBackend).toBe('tauri-native');
      expect(caps.canRunGenerative).toBe(true);
    });

    it('returns webgpu-webllm generative backend with WebGPU + sufficient memory', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 8,
        hardwareConcurrency: 8,
        isDesktop: false,
        hasAppleFoundationModels: false,
      });

      expect(caps.generativeBackend).toBe('webgpu-webllm');
      expect(caps.canRunGenerative).toBe(true);
    });

    it('returns none generative backend with WebGPU but low memory', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 2,
        hardwareConcurrency: 4,
        isDesktop: false,
        hasAppleFoundationModels: false,
      });

      expect(caps.generativeBackend).toBe('none');
      expect(caps.canRunGenerative).toBe(false);
    });

    it('always reports canRunClassification as true', () => {
      // Even on weakest device, WASM fallback ensures classification works
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: false,
        deviceMemory: 0,
        hardwareConcurrency: 1,
        isDesktop: false,
        hasAppleFoundationModels: false,
      });

      expect(caps.canRunClassification).toBe(true);
      expect(caps.classificationBackend).toBe('wasm');
    });

    it('preserves raw capability values in the report', () => {
      const caps = detectCapabilitiesFromEnv({
        hasWebGPU: true,
        deviceMemory: 16,
        hardwareConcurrency: 12,
        isDesktop: true,
        hasAppleFoundationModels: true,
      });

      expect(caps.hasWebGPU).toBe(true);
      expect(caps.deviceMemory).toBe(16);
      expect(caps.hardwareConcurrency).toBe(12);
      expect(caps.isDesktop).toBe(true);
      expect(caps.hasAppleFoundationModels).toBe(true);
    });
  });
});
