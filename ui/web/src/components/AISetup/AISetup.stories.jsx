import AISetup from './AISetup'

export default {
  title: 'Components/AISetup',
  component: AISetup,
}

export const Default = {
  args: {
    onComplete: () => {},
  },
}

export const Compact = {
  args: {
    onComplete: () => {},
    compact: true,
  },
}
