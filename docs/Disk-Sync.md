# Disk in Finder

inbox2 Disk as a location in the Finder sidebar, like Dropbox. Files stay online until someone opens them; folders can be kept on the Mac; edits made offline upload later. Turned on in the desktop app under Settings › Disk. macOS 15 or later. Windows (Cloud Files API) is not built.

Decided 2026-11-22 (design and research: `inbox2-internal/docs/plans/disk-design/disk-in-finder.html`, decisions in `disk.md` risk 7): a replicated File Provider extension inside Inbox2.app (not FUSE, not a second app), sealed shares in v1, pages as read-only `.page` files, online-only by default, macOS 15 minimum, and sealed shares only while FileVault is on.

## Parts

| Part | Where | Does |
|---|---|---|
| Server feed | `api/app/controllers/api/v1/disk/sync_controller.rb` | Changes to Disk nodes since a cursor (below) |
| Engine | `ui/desktop/core/src/disk/` | Pulls the feed into `disk.db`, lists, downloads, uploads, conflicts, sealed crypto |
| Extension | `ui/desktop/fileprovider/` (Swift, xcodegen) | `NSFileProviderReplicatedExtension` over the engine's UniFFI `DiskSession` |
| App side | `ui/desktop/src-tauri/src/disk_finder.rs` | Writes the config, registers the Finder location, FileVault check, 30 s signal |
| Settings | `ui/web/src/pages/settings/DiskFinderSettings.jsx`, `lib/diskFinder.js` | The switch, state, drives, speeds; the tray row in `pages/tray/TrayPage.jsx` |

## How a change travels

- **Server to Mac.** macOS calls `enumerateChanges` when the app signals the working set (every 30 s) or Finder looks. The extension pulls the feed first (at most every 20 s), then answers from the engine's change log (`changes`, one row per store write). The sync anchor is that log's newest rev; an anchor older than the trimmed log answers `syncAnchorExpired` and macOS lists again.
- **Mac to server.** macOS calls `createItem`, `modifyItem`, `deleteItem`. A retryable failure is returned as `serverUnreachable`: macOS keeps the change and calls again. So the engine keeps no queue of its own, only the upload in flight (`uploads` table: reservation id, source fingerprint, sealed record) so the retry sends the parts storage lacks.
- **Merge base.** macOS hands back the content version an edit started from. That is `base_version` on completion; a 409 `version_conflict` keeps the server's file and uploads the Mac's copy beside it as `Offer (Waseem's conflicted copy 2026-11-22).docx`. Renames and moves are last writer wins.
- **Delete** moves to the inbox2 trash, never purges.
- **Reconcile.** `reconcile` or `cursor_expired` from the pull makes the engine diff `sync/keys` against the store: what left view is deleted, what changed or came into view is hydrated from `sync/nodes`.
- **Shared with me.** A node granted from someone else's C:\ has a parent the member can't see. It goes under a virtual "Shared with me" folder and moves back when its parent comes into view (`rehome_orphans`).

## Transfers and retries

- Requests retry three times with full-jitter backoff (0.5 s base, 4 s cap), then report `Offline` and macOS retries later. 401 is `SignedOut`, 404 `NotFound`, 413/507 `StorageFull`, other 409s and 422s are named errors macOS shows.
- Uploads use the existing multipart reservation (part size fixed by the API, never changed on resume). A changed source (size or mtime) aborts the old reservation and starts again.
- Downloads go to `staging/<version>.part` in the group container and continue with `Range: bytes=n-` after a drop. Version objects never change, so a partial file is always safe to continue.
- Speed limits (Settings) sleep between parts and reads to stay under the KiB/s set.

## Sealed shares

The engine opens sealed scopes with the member's X25519 identity key: key grant, epoch chain, names, version keys, manifests and chunks, byte for byte as `ui/web/src/lib/disk/crypto.js` (`core/src/disk/sealed.rs`, vectors in `core/testdata/disk_vectors.json`). A sealed upload reserves first (the manifest binds the version id), then seals to a staging file with a fresh version key; the wrapped key and prefix are kept with the reservation so a resume re-seals to the same bytes. Names in a sealed folder are made unique on the Mac, as the web client does.

**FileVault rule.** Sealed files opened in Finder sit decrypted under `~/Library/CloudStorage`. So the app writes the identity key into `config.json` only while `fdesetup status` says FileVault is on, and its 30 s tick removes the key and evicts every downloaded sealed file when FileVault goes off. Without the key, sealed items show as locked ("Sealed item abc123", read-only, no content). The key reaches the app from the web client's unlocked identity (`e2eeStore.identityKeys`), on enable and after an unlock.

`config.json` lives in `~/Library/Group Containers/KF53B4S5HD.<app id>/Disk/` with mode 0600. macOS 15 limits a group container to apps signed by our team with the group entitlement.

## Settings

- **Show Disk in Finder** adds or removes the location (`NSFileProviderManager`). Removing keeps edits that didn't upload in a folder macOS names.
- **New files**: online-only, or "Keep on this Mac" (`contentPolicy = downloadEagerlyAndKeepDownloaded` on the drive roots).
- **Drives in Finder**: hidden drives read as deleted to macOS and come back when shown.
- **Pause** disconnects the domain; macOS shows it paused in Finder.
- One org at a time: turning it on in another org replaces the location.

Pages appear as `<name>.page`, a small JSON file with the page's link. The app is registered for `.page` (`com.inbox2.page`) and opens the link in the browser, where Disk lives.

## Build and release

`ui/desktop/fileprovider/build.sh` builds the core as a static library with `mobile-ffi`, generates the Swift bindings, builds the `.appex` (xcodegen + xcodebuild) and signs it with its own entitlements (sandbox, network client, the app group). Tauri copies it to `Contents/PlugIns` through `bundle.macOS.files` and does not sign nested extensions, which is why the script signs first. `yarn install:app[:dev]`, `bin/release-desktop` and `desktop.yml` all run it. The app's own `entitlements.plist` carries both app groups (prod and dev).

## Tests

- `cd ui/desktop/core && cargo test --lib disk::`: store, API error mapping, backoff, throttle, the engine against a mock API (pull, list, fetch, upload, conflict copy, resume of a dropped upload, hidden drives, keep downloaded), the sealed round trip (names open, downloads decrypt, uploads seal, locked without the key) and the sealed vectors.
- `cd ui/web && npx vitest run --project unit src/lib/__tests__/diskFinder.test.js`: the status wording.
- The server side: `spec/requests/api/v1/disk/sync_spec.rb`, `spec/services/disk_sync_triggers_spec.rb`.

## Not built yet

- Windows (Cloud Files API). The engine is host-agnostic; it needs a cfapi adapter and an MSIX build.
- Push instead of the 30 s signal: the extension pulls when signalled or when Finder looks.
- Several orgs at once (one location per org), thumbnails from the server, Finder sharing menu items ("Copy inbox2 link").
- Sealed page content (pages open in the browser).


## Server feed

A local mirror of a member's Disk (the macOS File Provider) keeps itself current through four read-only endpoints. They follow the MX sync feed ([MX-Sync.md](MX-Sync.md)): the same cursor, the same horizon rule, the same "visibility loss arrives as a delete". Writes go through the normal Disk endpoints (`uploads`, `nodes/:id/move`, …).

All paths are under `/api/v1/orgs/:org/disk/sync/`. A person who is not a member of `:org` gets 404. A plan without Disk gets 403. In the read-only month after a downgrade, all four keep working, because they are GETs.

Code: `Api::V1::Disk::SyncController`, `Disk::SyncNodeSerializer`, `Disk::SyncTriggers` (the triggers), `Disk::SyncEvent` (the event rows), `SyncCursor` (the cursor helpers, shared with the MX feed).

### What the feed covers

One team (`:org`) as the member sees it, plus their own C:\ (it lives in the person's personal workspace org, `Disk::Node.c_root_for`). It also covers nodes on another person's C:\ that the member has a grant on. `Disk::Access.scope_for(membership)` decides visibility. The mirror holds a node when that scope returns it, it is not in the trash (`trashed_at`), it is not staged (`pending_until`), and its share is not in the trash.

### Change tracking

- `disk_nodes.change_seq` / `change_xid`: set by a `BEFORE INSERT OR UPDATE` trigger (`sync_stamp()`, with the same `sync_change_seq` sequence the MX tables use). Every write gets them, `update_all` included. `change_seq` is the node's version.
- When a node changes parent, the trigger sets a new `change_seq` on all of its subtree. A folder moved into view then arrives with its contents. (ponytail: a move within view re-sends the subtree too.)
- `disk_sync_events(organization_id, kind, node_key, change_seq, change_xid, created_at)`:
  - `deleted`: a node row was deleted (purge, org wipe), or the node moved to another org (C:\ ↔ a team share). The event goes into the org the node left.
  - `acl`: one row per org that a statement on `disk_grants`, `disk_share_memberships`, `disk_key_grants` or `disk_shares` touched. A grant also writes one into the grantee membership's org, so revoking a grant on someone else's C:\ still reaches the grantee.
- A `disk_shares` update also sets a new `change_seq` on the share's root node. The share's name lives in `share_name` on that root.
- Events are kept 30 days (`Disk::SyncEvent::RETENTION`). `SyncTombstonePruneJob` prunes them daily, and keeps each org's newest expired event as its watermark.

The triggers are installed by migration `20261122130001` and after every schema load (`config/initializers/sync_triggers.rb`). `spec/services/disk_sync_triggers_spec.rb` fails if any of them is missing.

### The cursor

An opaque string `"<xid>.<seq>"`, the same format as in MX. A blank cursor means "from the beginning". A pull walks `(change_xid, change_seq)` over disk_nodes and disk_sync_events of the orgs in the feed, one ordered index scan per org. It returns only rows written by transactions older than the oldest one still running (the horizon). A commit that is slow to land can therefore never fall behind a cursor that has already moved past it. When a pull drains everything, the cursor jumps to the horizon.

### `GET sync/head`

```json
{ "cursor": "58575834.0" }
```

Take this before a first full sync with `keys` + `nodes`, then pull from it.

### `GET sync/pull?since=<cursor>&limit=<n>`

`limit` defaults to 200, maximum 500. An "acl" event takes a place in the page too.

```json
{
  "cursor": "58575834.3912",
  "has_more": false,
  "cursor_expired": false,
  "reconcile": false,
  "nodes": [ <node>, ... ],
  "deleted": ["dnd_…", ...]
}
```

- `nodes`: the changed nodes the mirror should hold, in cursor order.
- `deleted`: node ids to drop. These are changed nodes the member no longer sees, nodes that are trashed or staged, and nodes that were purged or moved to another org. Dropping a folder drops its subtree. An id the mirror never had is harmless: ignore it. (Because the feed covers the whole org, a changed node in a share the member is not in also comes back here.)
- `reconcile`: true when an "acl" event falls in this page, or when `cursor_expired` is true. Access changed in a way that touched no node, for example a share membership or a grant that was removed or added. The client then walks `keys` and fixes the difference.
- `has_more`: pull again with the new cursor at once.
- `cursor_expired`: the cursor is older than the pruned-event watermark, or it was issued by another database (its xid is past every xid this one has handed out). The client keeps the returned cursor and reconciles.
- 422 `Invalid cursor` for a cursor that cannot be parsed.

### `GET sync/keys?after=<node id>`

```json
{ "keys": [["dnd_…", 3908], ...], "next": "dnd_…" }
```

Every node the mirror should hold, with its `change_seq`. Paged by key, 5000 per page. `next` is null on the last page. Compare against the mirror: drop what is not listed, and fetch with `nodes` what is missing or has a different `change_seq`.

### `GET sync/nodes?ids[]=…`

```json
{ "nodes": [ <node>, ... ], "missing": ["dnd_…"] }
```

At most 200 ids per call (more is 422). `missing` names the ids the member cannot see or that do not exist. Another org's ids are always missing.

### Node shape

```json
{
  "id": "dnd_…",
  "parent_id": "dnd_…" | null,
  "drive": "c" | "dsh_…" | "shared",
  "share_name": "Marketing" | null,
  "kind": "folder" | "file" | "page",
  "name": "deck.pdf" | null,
  "mime": "application/pdf" | null,
  "sealed": false,
  "metadata_ciphertext": "<base64>" | null,
  "key_epoch": 1 | null,
  "seal_scope_id": "dnd_…" | null,
  "size_bytes": 5,
  "content_modified_at": "…" | null,
  "updated_at": "…",
  "change_seq": 3908,
  "current_version": {
    "id": "dvr_…", "size_bytes": 5, "created_at": "…",
    "chunk_bytes": 1048576, "key_epoch": 1, "wrapped_key": "<base64>", "manifest_ciphertext": "<base64>"
  } | null,
  "can_write": true
}
```

- `parent_id` is null for a drive root. It can also name a folder the member cannot see: the node is then the top of a grant. Show it at the top of its drive.
- `drive`: `"c"` is the member's own C:\. A share id means a team share. `"shared"` means a node on another person's C:\ that reaches the member through a grant.
- `share_name` is set on an unsealed share's root only.
- A sealed node never carries `name` or `mime`. It carries `metadata_ciphertext` (base64), `key_epoch` and `seal_scope_id` (its scope root). A sealed version adds `chunk_bytes`, `key_epoch`, `wrapped_key` and `manifest_ciphertext` (base64). An unsealed version has only `id`, `size_bytes` and `created_at`.
- `can_write`: the member's role there (`Disk::Access.role`) is edit or manage. It is false in an archived share for everyone but owners and admins. It is a hint for the UI: the write endpoints check again. A role change that touches no node (for example a share membership going from edit to view) only sets `reconcile`, and `change_seq` stays the same. `can_write` can therefore lag until the node changes next.

### Writing back: conflicts

To save a new version of an existing file, reserve an upload with `node_id` and the version the edit started from:

```
POST disk/uploads           { node_id, size_bytes, base_version: "dvr_…", ... }
POST disk/uploads/:id/complete { sha256, base_version?: "dvr_…" }
```

The upload stores `base_version` (`disk_uploads.base_version_key`). If it is given at completion, it replaces the one from the reservation. When the upload commits, the server locks the node in the committing transaction and compares its current version with that base. If they differ, the answer is:

```json
409 { "errors": [...], "code": "version_conflict", "current_version_id": "dvr_…" }
```

No version is made. The upload is not aborted: it goes back to `reserved` and its bytes stay. The client can do one of these:

- Overwrite: complete again with `base_version` set to the `current_version_id` it was given.
- Keep both: cancel the upload (`DELETE disk/uploads/:id`) and upload the file again as a new file.

Without `base_version`, the behaviour is the same as before (the web client): the newest upload wins.

### Writing back: idempotent completion

`POST uploads/:id/complete` on an upload that is already done (the uploads are the member's own) answers 200 with the same node and version as the first time. It never makes a second version, and it ignores the body, `base_version` included. A client that lost the first response can simply send it again.

### Not covered yet

- Changes to a member's role or domain access (admin promotion or demotion, the team domains they reach) emit no event. Open and admin-only shares appear or disappear only at the next node change or reconcile.
- Agent memberships use the feed through `scope_for` like anyone else. The feed does not add the orgs reached by their agent grants.
