// Deliberately empty: the package exists to link the three MediaPipe GenAI
// xcframeworks, and the app imports `MediaPipeTasksGenAI` from them directly
// (BridgeLLM gates on `#if canImport(MediaPipeTasksGenAI)`). The upstream
// wrapper's source files are empty for the same reason.
