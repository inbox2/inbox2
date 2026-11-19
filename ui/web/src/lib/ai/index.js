// AI Module — client-side on-device inference for Inbox2
// Tier A: sentiment, intent classification, text embeddings
// Tier B: generative smart replies and summarization

export { detectCapabilities, detectCapabilitiesFromEnv } from './capabilities';
export { matchBackends, createGenerativeProvider } from './matching';
export { MODEL_REGISTRY, getTierADownloadSizeMB, MODEL_HOST_URL } from './models';
export {
  hasAIConsent,
  setAIConsent,
  getModelStatuses,
  allModelsReady,
  downloadAllModels,
  removeAllModels,
  getModelDiskUsage,
} from './modelManager';
export {
  initializeInference,
  analyzeSentiment,
  classifyIntent,
  generateEmbedding,
  isInferenceReady,
  disposeInference,
} from './inference';
export { useAIClassification } from './useAIClassification';
export {
  initializeGenerative,
  isGenerativeAvailable,
  isGenerativeReady,
  generativeUnavailableReason,
  generateSmartReplies,
  summarizeThread,
  generate,
  getGenerativeBackend,
  disposeGenerative,
} from './generative';
