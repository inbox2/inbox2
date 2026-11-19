# Mail clients: IMAP and SMTP submission

Reading and sending inbox2-hosted mail from Apple Mail, Thunderbird, Outlook or
anything else that speaks IMAP and SMTP. Off by default; an org admin switches
it on. Decisions and their dates: [plans/mail-clients.md](plans/mail-clients.md).

## Shape

```
mail client ──IMAP 993 / SMTP 465 (TLS)──▶ Go `imap` (mta/cmd/imap) ──HTTP──▶ Rails /api/v1/mail-client
```

The Go process speaks the protocols and holds no mail. Rails owns everything
that is inbox2: who may sign in, which mail is theirs, folders, message
numbers, flags, the message bytes, sending. The Go process signs in to Rails
with the person's own app password on every request, so it can never read more
than that person can.

## What a mail client sees

- **A person's own mailbox only**: threads to or from their own addresses and
  their private (imported) mail. The shared domain inbox is never served.
- **Folders**: `INBOX`, `Archive`, `Sent`, `Trash`, `Junk`. No Drafts folder:
  a client keeps its drafts locally.
- A thread's state is the message's state. Read, archive, trash and junk in a
  mail client change the thread in inbox2, and the other way round.
- **Not served**: sealed domains (the server holds ciphertext only).

## The contract: `/api/v1/mail-client`

Every request carries HTTP Basic credentials: the login (one of the person's
addresses) and an app password. `401` = bad credentials. `403` = signed in but
not allowed (the org has not switched mail clients on, or the domain is
sealed); the body's first error message is shown to the person.

Folder names in paths are the five above, exactly. UIDs are per folder and
only grow. `uidvalidity` is fixed per person and folder.

| Call | Request | Response |
|---|---|---|
| `GET session` | | `{"login": "jane@acme.com", "name": "Jane"}` |
| `GET folders` | | `{"folders": [{"name": "INBOX", "special_use": null, "uidvalidity": 1, "uidnext": 42, "exists": 30, "unseen": 4}, …]}`. `special_use` is `"\\Archive"`, `"\\Sent"`, `"\\Trash"`, `"\\Junk"` or null. |
| `GET folders/:name/messages` | | `{"uidvalidity": 1, "uidnext": 42, "messages": [{"uid": 7, "flags": ["\\Seen"], "internal_date": "2026-11-11T10:00:00Z", "size": 5120}, …]}` ascending by uid, the whole folder. |
| `GET folders/:name/messages/:uid/header` | | The header block, raw bytes, ending in an empty line. `Content-Type: message/rfc822`. Cheap. |
| `GET folders/:name/messages/:uid/raw` | | The whole message, raw bytes, exactly `size` long. May be slow (attachments). |
| `POST folders/:name/flags` | `{"uids": [7, 8], "mode": "add"\|"remove"\|"set", "flags": ["\\Seen", "\\Flagged"]}` | `{"messages": [{"uid": 7, "flags": […]}, …]}` |
| `POST folders/:name/move` | `{"uids": [7], "to": "Archive"}` | `{"moved": [{"uid": 7, "to_uid": 12}]}`. A uid that could not move is absent. |
| `POST folders/:name/expunge` | `{"uids": [7]}` or `{}` for every `\\Deleted` message | `{"expunged": [7]}` |
| `POST folders/:name/search` | `{"from": "…", "to": "…", "subject": "…", "text": "…", "since": "2026-11-01", "before": "2026-12-01"}`, any subset | `{"uids": [3, 7]}` |
| `POST folders/:name/append` | `{"raw_b64": "…", "flags": []}` | `200 {"uid": 9}` when the message is already there (a client filing its own sent copy); `422` otherwise. |
| `POST submit` | `{"mail_from": "jane@acme.com", "rcpt_to": ["a@example.com"], "raw_b64": "…"}` | `200 {"id": "msg_…"}`; `403` when the person may not send as that address; `422` with a message otherwise. |

Flags Rails understands: `\Seen`, `\Flagged`, `\Answered`, `\Deleted`,
`$Forwarded`. Others are stored and returned as given.

Errors are the API's usual shape: `{"errors": [{"message": "…"}], "status": 422}`.

## How the Rails side works

- **Sign-in**: `MailClientPassword` (`imc_…`), one per mail client, made by the
  member in inbox2 and shown once. The account password is never accepted: a
  passkey, a TOTP code or SAML may sit in front of it, and IMAP can ask for
  none of them. The login must be one of the member's own mailbox addresses.
- **Paid plans only** (decided 2026-11-11): `Plan#mail_clients?`. An
  organization on Free cannot turn the switch on, and a downgrade to Free
  closes access without touching the switch (`Organization#mail_clients_open?`).
- **The switch**: `organizations.mail_clients_enabled`, default off, set by an
  admin through `PATCH /orgs/:org {mail_clients_enabled}`. While it is off no
  app password can be made and every mail-client request answers 403.
- **Whose mail**: `Conversation.personal_to(membership)`: threads stamped as
  the member's personal mail when they started (`personal_membership_id`), and
  private (imported) threads they own. Ownership only: a shared thread that
  names their address, or a colleague's thread they were given access to, is
  not served, because a mail client could change it for everyone. Drafts and
  sealed messages are left out.
- **Folders** are derived from the thread's status (`MailClient::Mailbox`):
  trash → Trash; a sent message → Sent; spam → Junk; archived → Archive;
  anything else → INBOX. Moving a message sets the thread's status, so the
  whole thread moves. A sent message can only go to Trash and back; any other
  move leaves it and its thread untouched. A move into or out of Junk trains
  the junk filter.
- **UIDs**: `imap_messages` holds one row per person and message (folder, UID,
  extra flags); `imap_folders` holds each folder's UIDVALIDITY and next UID.
  `reconcile!` runs when a client looks, and gives a fresh UID to every
  message that is new or has changed folder. A message is in one folder per
  person, so its flags survive a move.
- **Flags**: `\Seen` is the thread's read state. Every other flag is stored
  on the `imap_messages` row and means nothing to inbox2.
- **Deleting**: outside Trash, an expunge moves the thread to Trash. Inside
  Trash it only hides the message from mail clients. A mail client can
  therefore never remove mail for good.
- **COPY** is carried out as a move: a message cannot be in two folders.
- **The message bytes** (`MailClient::Mime`): the original header block
  (`messages.raw_headers`, kept from 2026-11-11 for inbound mail and for mail
  submitted by a client) without the headers that described the original body,
  then the body rebuilt from the parsed fields: plain and HTML as
  `multipart/alternative`, attachments under `multipart/mixed`, everything
  base64, boundaries derived from the message's id. The same bytes every time.
  The listed size is computed without fetching attachments.
- **Sending** (`MailClient::Submit`): the envelope sender and the From header
  must both be addresses the member may send as. The message becomes a normal
  sent message (threaded by `In-Reply-To`/`References` into the member's own
  thread when there is one) and goes out through `OutboundDeliveryJob`, with
  no undo window. Recipients in the envelope but not in To or Cc are Bcc; a To
  or Cc address missing from the envelope is refused, so the message goes to
  the envelope and nobody else.
  Attachments are stored before the message is committed, so a failed upload
  leaves nothing behind. The member's own repeated Message-ID is answered and
  queued again if it never was; someone else's is refused.
- **A member's settings**: `GET /orgs/:org/mail-client` (hosts, ports, their
  addresses) and `…/mail-client/passwords` (list, create, revoke).

## Limits to know

- A signature over the body (DKIM, S/MIME, PGP/MIME) will not verify in the
  mail client: the body is re-encoded. The headers are the originals.
- A personal thread from before threads were stamped with their owner
  (2026-10-24) is not served.
- Mail that arrived before 2026-11-11 has rebuilt headers (From, To, Cc,
  Subject, Date, Message-ID, In-Reply-To, References).
- Inline images arrive as attachments.
- No Drafts folder, no folder creation, no import by dragging mail in.
- `reconcile!` and the folder listing read the person's whole mailbox index on
  every poll. Fine to tens of thousands of messages.
- There is no screen yet for the admin switch or for app passwords; both are
  API-only.

## Production (switched on 2026-11-11)

- `imap` runs in the mail role beside `mx` and `smtp` (`.pl.yaml`), with the
  certificate Pushleft issues for `mx.inbox2.com`.
- Public ports on `138.201.227.97`: 993 → IMAP (`:9930`), 465 → SMTP
  submission (`:4651`).
- It calls Rails at `http://api.inbox2.internal:4000/api/v1/mail-client`.
- Every organization is still off until its admin sets
  `mail_clients_enabled`.

## Screens

- **Console › Mail clients** (`/console/mail-clients`, `ConsoleMailClients.jsx`):
  the org switch, owners and admins on a paid plan. Nothing else.
- **Settings › Mail clients** (`pages/settings/MailClientsSettings.jsx`, every
  member, also in the phone's More menu): pick Outlook, Apple Mail, Thunderbird
  or another client, follow its steps, read the servers, create and delete app
  passwords. The section is listed only while the org has the switch on
  (`mailClients` in `settingsSections.js`).
- The product icons are in `ui/web/public/mail-clients/`, from Wikimedia
  Commons. They are trademarks of Microsoft, Apple and Mozilla.
