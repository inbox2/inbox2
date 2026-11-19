import { useCallback, useEffect, useState } from 'react'
import { MgmtButton, MgmtSelect } from '../../components/management'
import api from '../../lib/api'
import { API_ORIGIN } from '../../lib/apiOrigin'
import diskApi from '../../lib/disk/api'
import { AGENT_DISK_PERMISSIONS, ROLE, ROLE_LABEL } from '../../lib/disk/model'
import { formatPath, pathSegments } from '../../lib/disk/paths'
import { MoveDialog } from '../disk/DiskDialogs'
import styles from './console.module.css'
import own from './ConsoleDisk.module.css'

/* Agents in Disk (spec F12): the three Disk permissions per agent, the folders
   and shares it may reach (grants, view or edit), and how to connect it over MCP.
   Agents get nothing in Disk until both a permission and a grant are given. */
export default function DiskAgents({ orgId, orgSlug }) {
  const [agents, setAgents] = useState(null)
  const [error, setError] = useState(null)
  useEffect(() => {
    api.listAgents(orgId).then((d) => setAgents(d.agents)).catch((e) => { setError(e); setAgents([]) })
  }, [orgId])
  const endpoint = `${API_ORIGIN || window.location.origin}/api/v1/orgs/${orgSlug}/disk/mcp`
  return (
    <div className={`${styles.card} ${styles.mt}`}>
      <div className={styles.cardHead}><h2 className={styles.cardTitle}>Agents</h2></div>
      <div className={own.pad}>
        <p className={own.muted}>
          An agent reaches Disk over MCP at <code>{endpoint}</code> with its <code>agt_</code> key as a bearer token.
          It sees only the folders and shares granted below, and only does what its Disk permissions allow. Sealed items never reach an agent.
        </p>
        {error && <p className={own.error} role="alert">{error.message}</p>}
        {agents?.length === 0 && !error && <p className={own.muted}>No agents in this organization yet.</p>}
        {agents?.map((a) => <AgentRow key={a.id} orgId={orgId} agent={a} onChange={(next) => setAgents((all) => all.map((x) => (x.id === next.id ? next : x)))} />)}
      </div>
    </div>
  )
}

function AgentRow({ orgId, agent, onChange }) {
  const [grants, setGrants] = useState(null)
  const [picking, setPicking] = useState(false)
  const [role, setRole] = useState(ROLE.VIEW)
  const [error, setError] = useState(null)
  const [key, setKey] = useState(null)
  const [drives, setDrives] = useState(null)
  const load = useCallback(() => diskApi.agentGrants(orgId, agent.id).then((d) => setGrants(d.grants)).catch(setError), [orgId, agent.id])
  useEffect(() => { load() }, [load])

  const perms = new Set(agent.permissions || [])
  const toggle = (p) => {
    const next = new Set(perms)
    if (next.has(p)) next.delete(p)
    else next.add(p)
    api.updateAgent(orgId, agent.id, { permissions: [...next] }).then((d) => onChange(d.agent)).catch(setError)
  }
  const grant = (nodeId) => diskApi.setAgentGrant(orgId, agent.id, nodeId, role).then(load).catch(setError)
  const remove = (nodeId) => diskApi.removeAgentGrant(orgId, agent.id, nodeId).then(load).catch(setError)
  const openPicker = () => { setPicking(true); if (!drives) diskApi.drives(orgId).then(setDrives).catch(setError) }
  const makeKey = () => api.agentCredential(orgId, agent.id).then((d) => setKey(d.token)).catch(setError)

  return (
    <section className={own.agent} aria-label={agent.name}>
      <h3 className={own.agentName}>{agent.name}{agent.status !== 'active' ? ` (${agent.status})` : ''}</h3>
      <fieldset className={own.perms}>
        <legend className={own.muted}>Disk permissions</legend>
        {AGENT_DISK_PERMISSIONS.map((p) => (
          <label key={p.value} className={own.perm}>
            <MgmtCheckbox  checked={perms.has(p.value)} onChange={() => toggle(p.value)} />
            {p.label}
          </label>
        ))}
      </fieldset>
      <p className={own.muted}>Disk access</p>
      {grants === null ? <p className={own.muted}>Loading...</p> : !grants.length ? <p className={own.muted}>No folders yet.</p> : (
        <ul className={own.grants}>
          {grants.map((g) => (
            <li key={g.node.id}>
              <span>{g.node.path?.length ? formatPath(pathSegments(g.node.drive, g.node.path)) : g.node.name}<small className={own.path}>{ROLE_LABEL[g.role]}, given by {g.granted_by?.name}</small></span>
              <MgmtButton size="sm" variant="ghost" onClick={() => remove(g.node.id)}>Remove</MgmtButton>
            </li>
          ))}
        </ul>
      )}
      <div className={own.row}>
        <MgmtSelect bare compact aria-label="Role for the new folder" value={role} onChange={(e) => setRole(e.target.value)}
          options={[ROLE.VIEW, ROLE.EDIT].map((r) => ({ value: r, label: ROLE_LABEL[r] }))} />
        <MgmtButton size="sm" variant="glass" onClick={openPicker}>Add a folder or share</MgmtButton>
        <MgmtButton size="sm" variant="ghost" onClick={makeKey}>New agt_ key</MgmtButton>
      </div>
      {key && <p className={own.muted} role="status">Copy this key now, it is shown once: <code>{key}</code></p>}
      {error && <p className={own.error} role="alert">{error.message}</p>}
      {picking && drives && (
        <MoveDialog orgId={orgId} drives={drives} movingIds={[]} verb="Give" onClose={() => setPicking(false)} onPick={(target) => { setPicking(false); grant(target) }} />
      )}
    </section>
  )
}

import { MgmtCheckbox } from '../../components/management';