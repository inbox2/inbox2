import LocalAgentsCard from './LocalAgentsCard'

export default {
  title: 'Components/LocalAgentsCard',
  component: LocalAgentsCard,
  parameters: {
    docs: {
      description: {
        component:
          'Settings card that detects locally-installed CLI agents (Claude Code, Codex, OpenCode, Gemini) and toggles them on/off. Desktop-only: it calls `detectLocalAgents()` over Tauri and renders `null` on the web build. In Storybook (no Tauri) it therefore shows nothing — the explainer below documents what it does.',
      },
    },
  },
}

export const Default = {
  render: () => (
    <div>
      <p>
        Desktop-only settings card. On the web build it renders nothing because
        there is no Tauri bridge to scan for installed CLI agents. On desktop it
        lists detected agents with on/off switches and any recent failed runs.
      </p>
      <LocalAgentsCard />
    </div>
  ),
}
