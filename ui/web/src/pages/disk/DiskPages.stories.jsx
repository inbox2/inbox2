import { useEffect } from 'react'
import { MemoryRouter, Routes, Route } from 'react-router'
import { expect, waitFor } from 'storybook/test'
import { AuthContext } from '../../hooks/AuthProvider'
import DiskLayout from './DiskLayout'
import DiskBrowser from './DiskBrowser'
import PublicLinkPage from './PublicLinkPage'
import useDiskStore from '../../stores/diskStore'

/* The Disk shell against fixture data: fetch is answered in the story, no API
 * runs. Fixtures follow api/app/serializers/disk/* exactly. */

const org = { id: 'org_demo', slug: 'acme', name: 'Acme', role: 'owner', domains: [] }
const ago = (d) => new Date(Date.now() - d * 86_400_000).toISOString()
const sara = { id: 'mem_sara', name: 'Sara Koch' }
const jonas = { id: 'mem_jonas', name: 'Jonas Lind' }
const node = (id, kind, name, x = {}) => ({
  id, kind, name, mime: null, sealed: false, size_bytes: kind === 'file' ? 2_400_000 : null,
  content_modified_at: ago(2), created_at: ago(20), trashed_at: null, metadata_ciphertext: null, key_epoch: null,
  short_id: id.slice(-21), drive: 'D', parent_id: 'dnd_mkt000000000000000000', share_id: 'dsh_mkt', current_version_id: null, starred: false, modified_by: sara,
  shared_with: { people: [], total: 0, inherited: true }, ...x,
})
const share = (id, name, icon, color, root, x = {}) => ({
  id, name, slug: name.toLowerCase(), icon, color, openness: 'assigned', org_role: 'view', archived_at: null, trashed_at: null, purge_at: null,
  created_at: ago(30), root_node_id: root, member_count: 4, ...x,
})

const drives = {
  c_drive: node('dnd_c00000000000000000000', 'folder', null, { drive: 'C', parent_id: null, share_id: null }),
  shares: [
    share('dsh_mkt', 'Marketing', 'marketing', '#e06a3d', 'dnd_mkt000000000000000000', { member_count: 12 }),
    share('dsh_fin', 'Finance', 'finance', '#c98a1b', 'dnd_fin000000000000000000', { member_count: 3 }),
    share('dsh_hr', 'HR', 'hr', '#8a5bd6', 'dnd_hr0000000000000000000', { member_count: 2, openness: 'org' }),
    share('dsh_prd', 'Product', 'product', '#2f7ad6', 'dnd_prd000000000000000000', { archived_at: ago(3) }),
  ],
  quota: { pool_bytes: 120 * 1024 ** 3, used_bytes: 46 * 1024 ** 3, reserved_bytes: 0, available_bytes: 74 * 1024 ** 3, percent_used: 38 },
}
const marketing = [
  node('dnd_launch000000000000000', 'folder', 'Launch 2026', { modified_by: jonas, shared_with: { people: [{ membership_id: jonas.id, name: jonas.name, avatar_url: null, role: 'edit' }, { membership_id: 'mem_mila', name: 'Mila Roos', avatar_url: null, role: 'view' }], total: 3, inherited: true } }),
  node('dnd_press0000000000000000', 'folder', 'Press kit'),
  node('dnd_pdf000000000000000000', 'file', 'Brand guidelines.pdf', { mime: 'application/pdf', size_bytes: 4_100_000, starred: true }),
  node('dnd_docx00000000000000000', 'file', 'Q4 plan.docx', { size_bytes: 212_000, modified_by: jonas, content_modified_at: ago(4) }),
  node('dnd_sealed000000000000000', 'file', null, { sealed: true, size_bytes: 88_000, metadata_ciphertext: 'AAAA', key_epoch: 1 }),
  node('dnd_deck00000000000000000', 'file', 'Launch deck.pptx', { size_bytes: 12_000_000 }),
  node('dnd_hero00000000000000000', 'file', 'hero.png', { mime: 'image/png' }),
  node('dnd_teaser000000000000000', 'file', 'teaser.mp4', { size_bytes: 84_000_000, modified_by: jonas }),
  node('dnd_zip000000000000000000', 'file', 'assets.zip', { size_bytes: 148_000_000, content_modified_at: ago(9) }),
  node('dnd_md0000000000000000000', 'file', 'README.md', { mime: 'text/markdown', size_bytes: 300, current_version_id: 'dvr_md' }),
  node('dnd_rb0000000000000000000', 'file', 'utm_report.rb', { size_bytes: 200, current_version_id: 'dvr_rb' }),
  node('dnd_csv000000000000000000', 'file', 'budget.csv', { mime: 'text/csv', size_bytes: 120, current_version_id: 'dvr_csv' }),
  node('dnd_svg000000000000000000', 'file', 'logo.svg', { mime: 'image/svg+xml', size_bytes: 400, current_version_id: 'dvr_svg' }),
  node('dnd_pdfmini00000000000000', 'file', 'One page.pdf', { mime: 'application/pdf', size_bytes: 600, current_version_id: 'dvr_pdf' }),
]

// A one-page PDF, built here so the offsets in its xref table are right.
function tinyPdf() {
  const text = 'BT /F1 28 Tf 72 700 Td (Brand guidelines) Tj ET'
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${text.length} >>\nstream\n${text}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ]
  let out = '%PDF-1.4\n'
  const offsets = objs.map((o, i) => { const at = out.length; out += `${i + 1} 0 obj\n${o}\nendobj\n`; return at })
  const xref = out.length
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`
  return out
}
const FILES = {
  dnd_md0000000000000000000: ['text/markdown', '# Marketing share\n\nEverything for the launch lives in `D:\\Marketing\\Launch 2026`.\n\n- Final assets go in **Press kit**\n- Never rename `hero.png`\n\n<img src="https://example.com/x.png" onerror="alert(1)">'],
  dnd_rb0000000000000000000: ['text/plain', "# UTM report\nrequire 'csv'\n\ndef report(rows)\n  rows.group_by { |r| r['utm_source'] }.transform_values(&:count)\nend\n"],
  dnd_csv000000000000000000: ['text/csv', 'Channel,Q3,Q4\nPaid social,12400,15000\nEvents,"8,000",22500\nContent,4200,4800\n'],
  dnd_svg000000000000000000: ['image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="160"><rect width="240" height="160" rx="16" fill="#2f7ad6"/><circle cx="80" cy="80" r="40" fill="#ffd9a0"/><script>alert(1)</script></svg>'],
  dnd_pdfmini00000000000000: ['application/pdf', tinyPdf()],
}
const fileUrl = (id) => URL.createObjectURL(new Blob([FILES[id][1]], { type: FILES[id][0] }))
const detail = (n, path) => ({ node: { ...n, path, access: { role: 'manage', sources: [{ kind: 'admin', role: 'manage', node_id: null, share_id: 'dsh_mkt' }] } } })
const mktRoot = node('dnd_mkt000000000000000000', 'folder', null, { parent_id: null })

const page = node('dnd_page00000000000000000', 'page', 'Launch playbook', { size_bytes: 900 })
const PAGE_MD = '# What we are shipping\n\nOne inbox for the whole domain, plus Disk.\n\n> [!NOTE]\n> Launch day is 14 November.\n\n## Checklist\n\n- [x] Brand guidelines signed off\n- [ ] Teaser video cut 4\n\n| Channel | Q4 |\n| --- | --- |\n| Events | 22,500 |\n\n[File: Brand guidelines.pdf](disk://dnd_pdfmini00000000000000)\n'
const linked = { id: 'dnd_pdfmini00000000000000', kind: 'file', name: 'One page.pdf', mime: 'application/pdf', size_bytes: 600, content_modified_at: ago(1) }

function respond(url, method) {
  let p = new URL(url, 'http://x').pathname.replace(/^.*\/disk/, '')
    // short ids (what URLs carry) to the full keys the fixtures use
    .replace(/\/(nodes|pages)\/(?!dnd_)([A-Za-z0-9_-]{21})(?=\/|$)/, '/$1/dnd_$2')
  if (p === '/links/tok') return { link: { password_required: false, unlocked: true, download_allowed: true, hide_download: false, abuse_email: 'abuse@example.test', node: linked }, folder: null, path: [], nodes: [], next_cursor: null }
  if (p === '/links/locked') return { link: { password_required: true, unlocked: false, download_allowed: true, abuse_email: 'abuse@example.test', node: null }, folder: null, path: [], nodes: [] }
  if (p === '/links/tok/download') return { download: { url: fileUrl('dnd_pdfmini00000000000000'), preview_url: fileUrl('dnd_pdfmini00000000000000'), node: linked } }
  if (p === '/pages/dnd_page00000000000000000') return { page: { revision: 1, ydoc: null, markdown: PAGE_MD, sealed: false, node_id: 'dnd_page00000000000000000' }, role: 'edit' }
  if (p === '/nodes/dnd_page00000000000000000') return detail(page, [{ id: 'dnd_mkt000000000000000000', short_id: 'dnd_mkt000000000000000000'.slice(-21), name: 'Marketing', sealed: false, kind: 'folder', share_slug: 'marketing' }, { id: 'dnd_page00000000000000000', name: 'Launch playbook', sealed: false }])
  if (method !== 'GET') return { node: marketing[0], results: [] }
  if (p === '' || p === '/') return drives
  if (p === '/nodes/dnd_mkt000000000000000000') return detail(mktRoot, [{ id: 'dnd_mkt000000000000000000', short_id: 'dnd_mkt000000000000000000'.slice(-21), name: 'Marketing', sealed: false, kind: 'folder', share_slug: 'marketing' }])
  if (p === '/nodes/dnd_c00000000000000000000') return detail(drives.c_drive, [{ id: 'dnd_c00000000000000000000', name: null, sealed: false }])
  if (p === '/nodes/dnd_mkt000000000000000000/children') return { nodes: url.includes('type=pages') ? [page] : marketing, count: marketing.length, total: marketing.length, next_cursor: null }
  if (p === '/nodes/dnd_c00000000000000000000/children') return { nodes: [], count: 0, total: 0, next_cursor: null }
  const dl = p.match(/^\/nodes\/([^/]+)\/download$/)
  if (dl && FILES[dl[1]]) return { download: { url: fileUrl(dl[1]), expires_at: ago(-1), size_bytes: 1 } }
  if (/\/versions$/.test(p)) return { versions: [{ id: 'dvr_x', number: 2, current: true, size_bytes: 300, created_at: ago(1), author: sara, has_thumbnail: false }, { id: 'dvr_y', number: 1, current: false, size_bytes: 280, created_at: ago(5), author: jonas, has_thumbnail: false }] }
  const one = p.match(/^\/nodes\/([^/]+)$/)
  if (one) return detail(marketing.find((n) => n.id === one[1]) || mktRoot, [{ id: 'dnd_mkt000000000000000000', short_id: 'dnd_mkt000000000000000000'.slice(-21), name: 'Marketing', sealed: false, kind: 'folder', share_slug: 'marketing' }, { id: one[1], name: 'x', sealed: false }])
  if (/\/grants$/.test(p)) return { grants: [{ role: 'edit', membership: jonas, granted_by: sara, node_id: 'x', created_at: ago(1) }] }
  if (/\/members$/.test(p)) return { members: [{ membership_id: sara.id, name: sara.name, role: 'manage' }, { membership_id: jonas.id, name: jonas.name, role: 'edit' }] }
  if (p === '/shares') return { shares: [] }
  if (p.startsWith('/views/')) return { nodes: marketing.slice(2, 5), next_cursor: null }
  return { members: [{ id: sara.id, status: 'active', user: { display_name: sara.name } }, { id: jonas.id, status: 'active', user: { display_name: jonas.name } }] }
}

// `delay` holds every answer back, so a story can see the loading state first.
const fakeFetch = (delay = 0) => async (url, opts = {}) => {
  if (/^(blob|data):/.test(String(url)) || String(url).includes('.wasm')) return realFetch(url, opts)
  if (String(url).includes('/links/unknown')) return new Response('{"errors":[{"message":"Not found"}]}', { status: 404 })
  if (delay) await new Promise((r) => setTimeout(r, delay))
  return new Response(JSON.stringify(respond(String(url), opts.method || 'GET')), { status: 200 })
}
const realFetch = window.fetch

// Hands the real fetch back when the story unmounts, unless the next story already swapped in its own.
function RestoreFetch({ mine, children }) {
  useEffect(() => () => { if (window.fetch === mine) window.fetch = realFetch }, [mine])
  return children
}
const withApi = (Story, { parameters }) => {
  const mine = fakeFetch(parameters.apiDelay)
  window.fetch = mine
  return <RestoreFetch mine={mine}><Story /></RestoreFetch>
}

function PublicShell({ at }) {
  return (
    <MemoryRouter initialEntries={[at]}>
      <Routes><Route path="/share/:a" element={<PublicLinkPage />} /><Route path="/share/:a/:b" element={<PublicLinkPage />} /></Routes>
    </MemoryRouter>
  )
}

function Shell({ at }) {
  return (
    <AuthContext.Provider value={{ organizations: [org], currentOrg: org, user: { username: 'sara' } }}>
      <MemoryRouter initialEntries={[at]}>
        <Routes>
          <Route path="/disk" element={<DiskLayout />}>
            <Route path="*" element={<DiskBrowser />} />
          </Route>
        </Routes>
      </MemoryRouter>
    </AuthContext.Provider>
  )
}

export default {
  title: 'Disk/Pages',
  decorators: [withApi],
  parameters: { layout: 'fullscreen' },
}

export const ShareFolder = { render: () => <Shell at="/disk/d/marketing" /> }
export const SharedDisk = { render: () => <Shell at="/disk/d" /> }
export const EmptyMyDisk = { render: () => <Shell at="/disk/c" /> }
export const Starred = { render: () => <Shell at="/disk/starred" /> }

/* Spec F1: nothing shifts when the content lands. The skeleton twin and the
   loaded list are measured in the same place; the header, the table, its
   columns and the first row must not move, and the page's layout-shift score
   (Chromium's layout-shift entries) must stay at zero. */
export const NoLayoutShift = {
  parameters: { apiDelay: 900 },
  loaders: [async () => { useDiskStore.getState().reset() }], // nothing cached: the skeleton must show
  render: () => <Shell at="/disk/d/marketing" />,
  play: async ({ canvasElement }) => {
    const box = (el) => { const r = el.getBoundingClientRect(); return { top: r.top, left: r.left, width: r.width, height: r.height } }
    const measure = () => ({
      table: box(canvasElement.querySelector('table')),
      head: [...canvasElement.querySelectorAll('thead th')].map(box),
      row: box(canvasElement.querySelector('tbody tr')),
      tools: box(canvasElement.querySelector('[role="search"]')),
    })
    await waitFor(() => expect(canvasElement.querySelector('table[aria-hidden], [aria-hidden] table')).toBeTruthy(), { timeout: 800 })
    // A web font swapping in is not a data shift: once the skeleton shows, let its faces finish loading first.
    await Promise.all(['400 15px Inter', '550 13px Inter', '600 15px Inter', '580 30px Fraunces', '500 13px "JetBrains Mono"'].map((f) => document.fonts.load(f).catch(() => null)))
    await document.fonts.ready
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    let cls = 0
    const main = canvasElement.querySelector('main')
    const supported = PerformanceObserver.supportedEntryTypes?.includes('layout-shift')
    const po = supported ? new PerformanceObserver((list) => list.getEntries().forEach((e) => {
      // Only shifts inside the browsing area count; the sidebar's share list grows by however many shares there are.
      if (!e.hadRecentInput && e.sources?.length && e.sources.every((x) => main.contains(x.node))) cls += e.value
    })) : null
    po?.observe({ type: 'layout-shift' })
    const skeleton = measure()
    await waitFor(() => expect(canvasElement.textContent).toContain('Brand guidelines.pdf'), { timeout: 4000 })
    await new Promise((r) => setTimeout(r, 200))
    const loaded = measure()
    po?.disconnect()
    expect(loaded.tools).toEqual(skeleton.tools)
    expect(loaded.table.top).toBe(skeleton.table.top)
    expect(loaded.head).toEqual(skeleton.head)
    expect(loaded.row).toEqual(skeleton.row)
    expect(cls).toBeLessThan(0.001)
  },
}

export const PreviewMarkdown = { render: () => <Shell at="/disk/d/marketing?open=f-md0000000000000000000" /> }
export const PreviewCode = { render: () => <Shell at="/disk/d/marketing?open=f-rb0000000000000000000" /> }
export const PreviewCsv = { render: () => <Shell at="/disk/d/marketing?open=f-csv000000000000000000" /> }
export const PreviewSvg = { render: () => <Shell at="/disk/d/marketing?open=f-svg000000000000000000" /> }
export const PreviewPdf = { render: () => <Shell at="/disk/d/marketing?open=f-pdfmini00000000000000" /> }
export const PreviewNone = { render: () => <Shell at="/disk/d/marketing?open=f-zip000000000000000000" /> }

export const Page = { render: () => <Shell at="/disk/d/marketing/Launch-playbook-page00000000000000000" /> }
export const PublicLinkFile = { render: () => <PublicShell at="/share/One-page.pdf/tok" /> }
export const PublicLinkPassword = { render: () => <PublicShell at="/share/locked" /> }
export const PublicLinkGone = { render: () => <PublicShell at="/share/unknown" /> }
