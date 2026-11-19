import AIBadge from './AIBadge';

export default {
  title: 'Components/AIBadge',
  component: AIBadge,
};

export const PositiveSentiment = {
  args: { type: 'sentiment', label: 'POSITIVE', score: 0.92 },
};

export const NegativeSentiment = {
  args: { type: 'sentiment', label: 'NEGATIVE', score: 0.87 },
};

export const QuestionIntent = {
  args: { type: 'intent', label: 'question', score: 0.78 },
};

export const RequestIntent = {
  args: { type: 'intent', label: 'request', score: 0.85 },
};

export const ComplaintIntent = {
  args: { type: 'intent', label: 'complaint', score: 0.71 },
};

export const FYIIntent = {
  args: { type: 'intent', label: 'FYI', score: 0.66 },
};

export const SchedulingIntent = {
  args: { type: 'intent', label: 'scheduling', score: 0.73 },
};

export const BelowThreshold = {
  args: { type: 'sentiment', label: 'POSITIVE', score: 0.45 },
};

export const AllBadges = {
  render: () => (
    <>
      <AIBadge type="sentiment" label="POSITIVE" score={0.9} />
      {' '}
      <AIBadge type="sentiment" label="NEGATIVE" score={0.85} />
      {' '}
      <AIBadge type="intent" label="question" score={0.8} />
      {' '}
      <AIBadge type="intent" label="request" score={0.75} />
      {' '}
      <AIBadge type="intent" label="complaint" score={0.7} />
      {' '}
      <AIBadge type="intent" label="FYI" score={0.65} />
      {' '}
      <AIBadge type="intent" label="scheduling" score={0.72} />
      {' '}
      <AIBadge type="intent" label="other" score={0.61} />
    </>
  ),
};
