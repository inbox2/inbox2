import AgentLogo from './AgentLogo'

export default {
  title: 'Components/AgentLogo',
  component: AgentLogo,
}

export const ClaudeCode = {
  render: () => <AgentLogo adapterId="claude-code" size={48} />,
}

export const Gemini = {
  render: () => <AgentLogo adapterId="gemini" size={48} />,
}

export const Codex = {
  render: () => <AgentLogo adapterId="codex" size={48} />,
}

export const OpenCode = {
  render: () => <AgentLogo adapterId="opencode" size={48} />,
}

export const UnknownFallback = {
  render: () => <AgentLogo adapterId="something-else" size={48} />,
}

export const AllVariants = {
  render: () => (
    <div>
      <AgentLogo adapterId="claude-code" size={32} />
      <AgentLogo adapterId="gemini" size={32} />
      <AgentLogo adapterId="codex" size={32} />
      <AgentLogo adapterId="opencode" size={32} />
      <AgentLogo adapterId="unknown" size={32} />
    </div>
  ),
}
