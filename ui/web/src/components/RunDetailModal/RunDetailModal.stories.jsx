import RunDetailModal from './RunDetailModal'

const noop = () => {}

export default {
  title: 'Components/RunDetailModal',
  component: RunDetailModal,
}

export const Succeeded = {
  args: {
    onClose: noop,
    onRerun: noop,
    run: {
      key: 'run_9a8b7c',
      adapter_id: 'claude-code',
      status: 'succeeded',
      duration_ms: 4230,
      cost_usd: 0.0182,
      input_tokens: 3120,
      output_tokens: 540,
      exit_code: 0,
      attempts: 1,
      finished_at: '2026-06-07T14:22:31.512Z',
      task: 'Extract the invoice PDF total and due date, then POST them to my automation webhook.',
      result_json: JSON.stringify({
        summary: 'Extracted invoice #4821: total $12,400, due 2026-06-30, and posted to the webhook.',
        log: [
          'Read attachment invoice-4821.pdf',
          'Parsed total = 12400.00 USD, due = 2026-06-30',
          'POST https://automation.inbox2.dev/hooks/invoice → 200 OK',
        ],
        data: { invoice: '4821', total: 12400, due: '2026-06-30' },
      }),
    },
  },
}

export const Failed = {
  args: {
    onClose: noop,
    onRerun: noop,
    run: {
      key: 'run_failed01',
      adapter_id: 'codex',
      status: 'failed',
      duration_ms: 1890,
      exit_code: 1,
      attempts: 2,
      finished_at: '2026-06-07T09:11:05.000Z',
      task: 'Summarize the thread and draft a reply.',
      error: 'Error: connection refused while reaching the on-device model socket.',
      result_json: null,
    },
  },
}

export const PendingMatch = {
  args: {
    onClose: noop,
    onRerun: noop,
    run: {
      adapter_id: 'gemini',
      status: 'awaiting_approval',
      task: 'Triage the message and apply the most appropriate priority label.',
      result_json: null,
    },
  },
}
