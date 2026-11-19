// WebLLM Generative Inference Worker
// Runs a quantized LLM in the browser via WebGPU using @mlc-ai/web-llm.
// Communicates with main thread via postMessage.

import * as webllm from '@mlc-ai/web-llm';

let engine = null;

const DEFAULT_MODEL = 'Qwen2.5-1.5B-Instruct-q4f16_1-MLC';

/**
 * Initialize the WebLLM engine with model download.
 */
async function initialize(modelId, onProgress) {
  const model = modelId || DEFAULT_MODEL;

  engine = new webllm.MLCEngine();

  engine.setInitProgressCallback((report) => {
    onProgress?.(report);
    self.postMessage({
      type: 'progress',
      payload: {
        text: report.text,
        progress: report.progress,
      },
    });
  });

  await engine.reload(model);
}

/**
 * Generate smart reply suggestions for an email.
 */
async function generateSmartReplies(emailText, senderName) {
  if (!engine) throw new Error('Engine not initialized');

  const prompt = [
    {
      role: 'system',
      content: `You are an email assistant. Generate exactly 3 short, natural reply suggestions for the email below. Each reply should be 1-2 sentences, a different tone (professional, friendly, brief). Return ONLY a JSON array of 3 strings, nothing else.`,
    },
    {
      role: 'user',
      content: `From: ${senderName}\n\n${emailText}`,
    },
  ];

  const response = await engine.chat.completions.create({
    messages: prompt,
    temperature: 0.7,
    max_tokens: 256,
    response_format: { type: 'json_object' },
  });

  const text = response.choices[0]?.message?.content || '[]';
  try {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed)) return parsed.slice(0, 3);
    if (parsed.replies) return parsed.replies.slice(0, 3);
    return [];
  } catch {
    // Try to extract array from response
    const match = text.match(/\[[\s\S]*?\]/);
    if (match) {
      try { return JSON.parse(match[0]).slice(0, 3); } catch { /* fall through */ }
    }
    return [];
  }
}

/**
 * Summarize an email thread.
 */
async function summarize(emailText) {
  if (!engine) throw new Error('Engine not initialized');

  const prompt = [
    {
      role: 'system',
      content: 'Summarize the following email thread in 2-3 concise bullet points. Focus on key decisions, action items, and deadlines. Be brief and factual.',
    },
    {
      role: 'user',
      content: emailText,
    },
  ];

  const response = await engine.chat.completions.create({
    messages: prompt,
    temperature: 0.3,
    max_tokens: 200,
  });

  return response.choices[0]?.message?.content || '';
}

/**
 * Free-form generation with a system prompt and user input.
 */
async function generate(systemPrompt, userInput, options = {}) {
  if (!engine) throw new Error('Engine not initialized');

  const prompt = [
    { role: 'system', content: systemPrompt },
    { role: 'user', content: userInput },
  ];

  const response = await engine.chat.completions.create({
    messages: prompt,
    temperature: options.temperature ?? 0.5,
    max_tokens: options.maxTokens ?? 300,
  });

  return response.choices[0]?.message?.content || '';
}

/**
 * Dispose engine and free GPU memory.
 */
async function dispose() {
  if (engine) {
    await engine.unload();
    engine = null;
  }
}

// ─── Message Handler ─────────────────────────────────────────────────────────

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;

  try {
    let result;
    switch (type) {
      case 'initialize':
        await initialize(payload?.modelId);
        result = { ready: true };
        break;
      case 'smart-replies':
        result = await generateSmartReplies(payload.text, payload.senderName);
        break;
      case 'summarize':
        result = await summarize(payload.text);
        break;
      case 'generate':
        result = await generate(payload.systemPrompt, payload.userInput, payload.options);
        break;
      case 'dispose':
        await dispose();
        result = { disposed: true };
        break;
      default:
        throw new Error(`Unknown message type: ${type}`);
    }
    self.postMessage({ id, type: 'result', result });
  } catch (err) {
    self.postMessage({ id, type: 'error', error: err.message });
  }
};
