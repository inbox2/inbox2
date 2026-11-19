// IPC wrappers for the in-core MCP server's settings card (docs/Vector-MCP.md).
// Desktop-only; the browser build never renders the card.
async function call(cmd, args) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke(cmd, args);
}

export const getMcpInfo = () => call('mcp_info');
export const setMcpEnabled = (enabled) => call('mcp_set_enabled', { enabled });
export const setMcpAgentAccess = (agentKey, level) => call('mcp_set_agent_access', { agentKey, level });

// An agent's access, from the least to the most. `full` also acts without
// asking: nothing in the app prompts for approval.
export const ACCESS_LEVELS = [
  { value: 'read', label: 'Read only' },
  { value: 'read_write', label: 'Read and change' },
  { value: 'full', label: 'Full access' },
];
