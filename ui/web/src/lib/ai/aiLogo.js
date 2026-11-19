/** The service's own mark for a writing-model lane (public/ai/). */
export function aiLogo(lane, variantId) {
  if (lane === 'native') return '/ai/apple.png'
  if (lane === 'openai') return '/ai/openai.png'
  return variantId?.startsWith('gemma') ? '/ai/gemma.png' : '/ai/qwen.png'
}
