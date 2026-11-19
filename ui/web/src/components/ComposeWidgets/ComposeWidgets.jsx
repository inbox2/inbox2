import { useState, useEffect } from 'react';
import useDrafts from '../../hooks/useDrafts';
import { useNewComposeFrom } from '../../hooks/useFromIdentities';
import { ToolbarButton } from '../ToolbarGroup';
import ComposePopup from '../ComposePopup';
import AISummaryPanel from '../AISummaryPanel';
import AIInsightsPanel from '../AIInsightsPanel';
import { ContextGroup } from '../ContextPanel';
import { messagePlainText } from '../../lib/messageText';
import { withShortcut } from '../../lib/shortcuts';

export function AISummaryGroup({ conversation }) {
  const [title, setTitle] = useState('Preview');
  const isAI = title === 'Summary';
  const lastMsg = conversation.messages?.[conversation.messages.length - 1];
  return (
    <ContextGroup icon="text.alignleft" title={title} badge={isAI ? 'AI' : undefined} collapseKey="ai-summary">
      <AISummaryPanel
        conversationId={conversation.id}
        threadText={conversation.messages?.map(m => `From: ${m.from_address}\n${messagePlainText(m)}`).join('\n---\n') || ''}
        messages={conversation.messages}
        cachedSummary={conversation.ai_summary}
        cachedSummaryKey={conversation.ai_summary_msg_key}
        onTitleChange={setTitle}
      />
      <AIInsightsPanel
        messageId={lastMsg?.id}
        plainText={messagePlainText(lastMsg)}
        message={lastMsg}
      />
    </ContextGroup>
  );
}

export function ComposeAction({ defaultFrom, rememberLast = false }) {
  const { createDraft } = useDrafts();
  const fromFor = useNewComposeFrom(defaultFrom, rememberLast);
  return (
    <ToolbarButton icon="square.and.pencil" variant="compose" onClick={() => createDraft({ fromAddress: fromFor() })} title={withShortcut('Compose', 'compose')}>
      Compose
    </ToolbarButton>
  );
}

export function ComposePopups() {
  const { openDrafts } = useDrafts();
  return openDrafts.map((draft, i) => (
    <ComposePopup key={draft.id} draft={draft} index={i} />
  ));
}

export function ComposeShortcuts({ defaultFrom }) {
  const { createDraft } = useDrafts();

  useEffect(() => {
    const handler = (e) => {
      const tag = e.target?.tagName;
      if (e.repeat || tag === 'INPUT' || tag === 'TEXTAREA' || e.target?.contentEditable === 'true') return;
      if ((e.key === 'c' || e.key === 'C') && (e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey) {
        e.preventDefault();
        createDraft({ fromAddress: defaultFrom });
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [createDraft, defaultFrom]);

  return null;
}
