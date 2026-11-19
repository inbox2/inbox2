import { describe, it, expect, vi, beforeEach } from 'vitest';

const invokeMock = vi.fn();
vi.mock('@tauri-apps/api/core', () => ({ invoke: (...a) => invokeMock(...a) }));
vi.mock('../tauri', () => ({ isTauri: () => true }));

import {
  detectLocalAgents,
  setLocalAgentEnabled,
  testRunAgent,
  listAgentRuns,
  listAgentApprovals,
  listFailedAgentRuns,
  upsertLocalRule,
  retryAgentRun,
  resolveAgentApproval,
  buildRulePayload,
  PERMISSION_MODES,
} from '../localAgents';

beforeEach(() => invokeMock.mockReset());

describe('localAgents IPC wrappers', () => {
  it('detectLocalAgents calls the command', async () => {
    invokeMock.mockResolvedValue([{ adapter_id: 'claude-code' }]);
    const r = await detectLocalAgents();
    expect(invokeMock).toHaveBeenCalledWith('detect_local_agents', undefined);
    expect(r[0].adapter_id).toBe('claude-code');
  });

  it('setLocalAgentEnabled passes camelCase args', async () => {
    await setLocalAgentEnabled('codex', true);
    expect(invokeMock).toHaveBeenCalledWith('set_local_agent_enabled', {
      adapterId: 'codex',
      enabled: true,
    });
  });

  it('testRunAgent forwards the full payload', async () => {
    await testRunAgent({
      adapterId: 'gemini',
      messageKey: 'm1',
      accountKey: 'a1',
      task: 'extract',
      permissionMode: 'full_auto',
    });
    expect(invokeMock).toHaveBeenCalledWith('test_run_agent', {
      adapterId: 'gemini',
      messageKey: 'm1',
      accountKey: 'a1',
      task: 'extract',
      permissionMode: 'full_auto',
    });
  });

  it('listAgentRuns nulls missing filters', async () => {
    invokeMock.mockResolvedValue([]);
    await listAgentRuns({ conversationKey: 'c1' });
    expect(invokeMock).toHaveBeenCalledWith('list_agent_runs', {
      conversationKey: 'c1',
      messageKey: null,
      limit: null,
    });
  });

  it('upsertLocalRule wraps the rule and returns its key', async () => {
    invokeMock.mockResolvedValue('lrul_x');
    const key = await upsertLocalRule({ name: 'x' });
    expect(invokeMock).toHaveBeenCalledWith('upsert_local_rule', { rule: { name: 'x' } });
    expect(key).toBe('lrul_x');
  });

  it('retry + approval resolve thread their keys', async () => {
    await retryAgentRun('arun_1');
    expect(invokeMock).toHaveBeenCalledWith('retry_agent_run', { runKey: 'arun_1' });
    await resolveAgentApproval('appr_1', true);
    expect(invokeMock).toHaveBeenCalledWith('resolve_agent_approval', {
      approvalKey: 'appr_1',
      approved: true,
    });
  });

  it('listAgentApprovals calls the command', async () => {
    invokeMock.mockResolvedValue([{ approval_key: 'appr_1', run_key: 'arun_1' }]);
    const r = await listAgentApprovals();
    expect(invokeMock).toHaveBeenCalledWith('list_agent_approvals', undefined);
    expect(r[0].run_key).toBe('arun_1');
  });

  it('listFailedAgentRuns passes a nullable limit', async () => {
    invokeMock.mockResolvedValue([]);
    await listFailedAgentRuns();
    expect(invokeMock).toHaveBeenCalledWith('list_failed_agent_runs', { limit: null });
  });
});

describe('buildRulePayload', () => {
  it('emits snake_case nested fields matching the Rust serde structs', () => {
    const payload = buildRulePayload({
      name: 'Invoices',
      accountKey: null,
      conditions: [{ field: 'from', op: 'contains', value: 'billing@acme.com' }],
      adapterId: 'claude-code',
      task: 'extract the invoice',
      permissionMode: 'approval_first',
      timeoutS: 90,
    });
    expect(payload).toMatchObject({
      key: '',
      name: 'Invoices',
      account_key: null,
      ai_gate: null,
      enabled: true,
      action: {
        type: 'run_agent',
        adapter_id: 'claude-code',
        permission_mode: 'approval_first',
        timeout_s: 90,
      },
    });
  });

  it('defaults the timeout', () => {
    const p = buildRulePayload({ conditions: [], adapterId: 'codex', task: 't', permissionMode: 'full_auto' });
    expect(p.action.timeout_s).toBe(120);
  });
});

describe('PERMISSION_MODES', () => {
  it('exposes the three posture options in order', () => {
    expect(PERMISSION_MODES.map((m) => m.value)).toEqual([
      'allowlist',
      'approval_first',
      'full_auto',
    ]);
  });
});
