# Connecting WhatsApp, Messenger & Instagram

This guide walks you through connecting **WhatsApp**, **Facebook Messenger**, and
**Instagram** to inbox2 so you can receive and reply to messages (and Page/Instagram
comments) from your unified inbox.

You connect your **own** Meta app. inbox2 never owns your Meta accounts — your app
secret and access token are encrypted and stay on your device. Most of the work is a
one-time setup in the Meta dashboard; after that, connecting in inbox2 takes about a
minute.

**Time:** ~15–20 minutes the first time.

---

## Before you start

You'll need an admin Facebook account and, depending on which channels you want:

| Channel | You need |
|---|---|
| **WhatsApp** | A WhatsApp Business Account (WABA) with a phone number added |
| **Messenger** | A Facebook Page |
| **Instagram** | An Instagram **professional** (Business/Creator) account. inbox2 connects it via **Instagram Login** (sign-in/OAuth) — a Facebook Page is *not* required. |

You can set up one, two, or all three — the steps are the same, with small differences
called out per channel.

> **Production vs. testing.** A brand-new Meta app works immediately with a few test
> recipients. To message the general public you must complete Meta's **App Review** and
> **Business Verification** (Step 8). Do the whole setup in test mode first, then submit
> for review.

---

## Step 1 — Create a Meta app

1. Go to **[developers.facebook.com](https://developers.facebook.com)** and sign in, then
   top-right → **My Apps** → **Create App** (or go straight to
   **[developers.facebook.com/apps/creation](https://developers.facebook.com/apps/creation/)**).
   The wizard walks through: **App details → Use cases → Business → Requirements → Overview**.
2. **App details:** enter an **app name** (e.g. "Acme Inbox") and your **contact email** →
   **Next**.
3. **Use cases:** tick the use case(s) for the channels you want — you can combine all of
   these on one app:

   | Channel you're connecting | Tick this use case |
   |---|---|
   | **WhatsApp** | **Connect with customers through WhatsApp** |
   | **Messenger** | **Engage with customers on Messenger from Meta** + **Manage everything on your Page** |
   | **Instagram** | **Manage messaging & content on Instagram** + **Manage everything on your Page** |

   **Manage everything on your Page** (the Pages API) is what lets you read and moderate
   Page comments, and Instagram connects through its linked Facebook Page — so tick it
   for Messenger *and* Instagram. WhatsApp doesn't need it. Then click **Next**.

   > Incompatible use cases are greyed out; the messaging + Page ones above combine fine.
   > You can't *remove* a use case after creation (but you can add more compatible ones
   > later) — if you ever need an incombinable one, create a separate app.

4. **Business:** connect or create your **Business portfolio** → **Next**.
5. **Requirements / Overview:** complete anything flagged, review, and click **Create app**
   (re-enter your password if prompted).

You're now on the app's **Dashboard**.

---

## Step 2 — Finish each product's setup

Selecting the use cases above adds the matching products to your app. Because you
created the app from **use cases**, you configure them on the **Customize use case** page:
left sidebar → **Use cases** → **Customize**. That page has a **dropdown at the top of the
left panel** to switch between your use cases, a **sub-menu** below it
(*Permissions and features*, *Messenger API Settings*, *Instagram settings*, …), and the
settings on the right.

- **WhatsApp:** on **Customize use case**, set the dropdown to **Connect with customers
  through WhatsApp**, open **WhatsApp → API Setup** (or **Configuration**), and confirm a
  **phone number** is added to your WhatsApp Business Account (add one if needed).
- **Messenger:** on **Customize use case**, set the dropdown to **Messenger from Meta** and
  click **Messenger API Settings**. On the right (**Messenger API Setup**), scroll to the
  **Generate access tokens** section and click **Connect** to add/select your **Facebook
  Page**. Connecting the Page is the only thing you need to do here — you can **ignore the
  Page access token** (inbox2 uses your System User token) and **skip "1. Configure
  webhooks"** (inbox2 fills the Callback URL + Verify token for you when you connect, Step 7).
- **Instagram** connects *through* a Facebook Page, so make sure **all** of these are true:
  1. Your Instagram **professional** (Business/Creator) account is **linked to the Page** —
     open the Page's **Professional dashboard → Linked accounts → Connect account** and
     sign in to Instagram. (You need an admin role on the Page.)
  2. **Assign the Instagram Tester role** (required while the app is in development mode,
     or you'll get **"Insufficient developer role"** when linking). App Dashboard →
     **App roles → Roles** → **Instagram Testers** → **Add Instagram Testers** → enter the
     Instagram **username**. Then **accept the invite from the Instagram side** (logged
     in as that account): go to **[instagram.com/accounts/manage_access/](https://www.instagram.com/accounts/manage_access/)**,
     open the **Tester Invites** tab, and click **Accept**. (Phone app alternative:
     **Settings and privacy → Apps and websites → Tester Invites**.) The row shows
     **Pending** until you accept; the invite can take a few minutes to appear.
  3. **Link the Instagram account / connect the Page to the app** — on **Customize use
     case** open the **Instagram settings** tab (or **Messenger API Settings**), and under
     **Generate access tokens** click **Add account** to add your Instagram account (and
     connect the same Page).

You do **not** need to add or configure a "Webhooks" product — inbox2 configures the
webhook for you when you connect (Step 7).

---

## Step 3 — Copy your App Secret

**WhatsApp + Messenger** (Facebook-Login path):

1. Left sidebar → **App settings** → **Basic**.
2. Next to **App secret**, click **Show**, enter your password, and **copy** it.

Keep it handy — you'll paste it into inbox2 in Step 7. (You do **not** need the App ID;
inbox2 detects it automatically.)

**Instagram uses a *separate* Instagram app id + secret** (the Instagram-Login path —
it's a distinct app credential, not the Facebook App Secret above). Find them at:

1. Left sidebar → **Use cases** → **Customize**.
2. Set the dropdown at the top of the left panel to **Instagram API**, then open
   **API setup with Instagram login**.
3. The card there shows **Instagram app ID** and **Instagram app secret** (click **Show**
   for the secret). Copy both — you'll paste them into inbox2 in Step 7.

> Instagram does **not** use the System User token or a Facebook Page here — it connects
> by signing in to the Instagram account (OAuth). See Step 7.

---

## Step 4 — Create a System User and generate a permanent token

A System User gives inbox2 a **permanent** access token (it never expires, so you won't
have to reconnect).

1. Go to **[business.facebook.com/settings](https://business.facebook.com/settings)**
   (Business Settings).
2. Left sidebar → **Users** → **System Users** → **Add**.
3. Name it (e.g. "inbox2"), set the role to **Admin**, and create it.
4. Select the system user → **Generate new token**.
5. Choose **your app** from the dropdown.
6. Set **Token expiration** to **Never**.
7. Under **Permissions**, tick the scopes for the channels you're connecting:

   - **WhatsApp:** `whatsapp_business_messaging`, `whatsapp_business_management`
   - **Messenger / Pages:** `pages_messaging`, `pages_show_list`,
     `pages_manage_metadata`, `pages_read_engagement`, `pages_manage_engagement`,
     `business_management`

   > **Instagram is different — skip it here.** inbox2 connects Instagram with
   > **Instagram Login** (you sign in to the Instagram account), *not* the System User
   > token. Its permissions are the `instagram_business_*` set and are configured inside
   > the Instagram product, not on this token — see Step 7. So if you're only connecting
   > Instagram, you don't need a System User token at all.

8. Click **Generate token** and **copy it now** — Meta shows it only once.

You'll paste this token into inbox2 in Step 7 (WhatsApp / Messenger only).

---

## Step 5 — Assign your assets to the system user

Still in **Business Settings**, give the system user control of the account it will
manage:

1. Left sidebar → **Users** → **System Users** → select your system user → **Assign assets**.
2. Tick each asset, with **Full control**:
   - **Apps:** your **app** (all channels — lets the system user act on the app).
   - **WhatsApp:** your **WhatsApp Account** (the WABA).
   - **Messenger / Instagram:** your **Page**.
3. **Save changes.**

(For Instagram you assign the **Page** it's linked to — not the Instagram account
directly.)

> Tip: it's fine to do this **before** Step 4 — assigning the assets first means the
> matching permissions are ready to tick when you generate the token.

---

## Step 6 — Find your asset ID

You need **one** ID, depending on the channel. Copy it for Step 7.

- **WhatsApp — WhatsApp Business Account ID (WABA):**
  In the app Dashboard → **WhatsApp** → **API Setup**. The **WhatsApp Business Account ID**
  is listed there. *(inbox2 finds the phone number automatically — you don't need the
  phone number ID.)*

- **Messenger — Facebook Page ID:**
  **Business Settings** ([business.facebook.com/settings](https://business.facebook.com/settings))
  → **Accounts** → **Pages** → click your Page; the **Page ID** is shown there.

- **Instagram — linked Facebook Page ID:**
  Use the **Page ID** of the Facebook Page your Instagram account is connected to — same
  place as Messenger (**Business Settings → Accounts → Pages**). *(inbox2 finds the
  Instagram account automatically.)*

---

## Step 7 — Connect in inbox2

Open inbox2 → **Add account** (Settings → Add account, or the **+** in the channel
switcher) → pick the channel.

**WhatsApp / Messenger** (Facebook-Login path) — fill the **three fields**:
- **App secret** — from Step 3.
- **System User token** — from Step 4.
- The one asset ID — from Step 6 (WhatsApp Business Account ID, or Facebook Page ID).
- Click **Connect**. inbox2 configures the webhook, subscribes the account, and starts
  receiving — no Meta Dashboard webhook setup required.

**Instagram** (Instagram-Login path) — connects by signing in, not by pasting a token:
1. **Register the redirect URI first.** Instagram requires an exact, **HTTPS** redirect
   URI (it rejects `http://localhost`), so inbox2 uses a stable cloud URL that bounces the
   sign-in back to the app. In your Instagram app → **Use cases → Customize → Instagram
   API → API setup with Instagram login → Business login settings**, add to **Valid OAuth
   Redirect URIs**:
   `https://test-api.inbox2.com/api/v1/oauth/instagram/callback`
   (replace the host with your inbox2 cloud API base if different). No localhost entry is
   needed — inbox2 captures the bounced code on a local port automatically.
   While you're on this screen, make sure the **Permissions** requested by Business login
   include `instagram_business_basic`, `instagram_business_manage_messages`, and
   `instagram_business_manage_comments` — that's exactly the set inbox2 asks for.
2. In inbox2, pick **Instagram**, paste your **Instagram app ID** + **Instagram app
   secret** (from Step 3), and click **Connect with Instagram**.
3. A browser opens to Instagram — log in to the professional account and approve. inbox2
   captures the result, exchanges it for a long-lived (60-day) token, and creates the
   account. (While the app is in development mode, sign in with an account that has a role
   /tester on the app — see Step 8.)

Repeat for each channel you want.

> **Adding another channel from the same Meta app?** If you've already connected one
> channel (say WhatsApp) and want to add another (Messenger or Instagram) from the **same
> Meta app**, you don't need to re-enter the App Secret and System User token. On the Add-
> account form, choose **Use existing** and pick the app from the dropdown — then you only
> need to supply the new channel's asset ID (Step 6). The shared credentials are copied
> from your existing connection's encrypted on-device store; they never leave the device.
> (Choose **Add new** to enter a different app's credentials instead.)

Your messages appear under the channel's sub-views (WhatsApp → Messages; Messenger →
All / Messages / Comments; Instagram → All / DMs / Comments / Mentions).

---

## Step 8 — Test it, then go live

1. **Send a test message** from a different account to your WhatsApp number / Facebook
   Page / Instagram — it should appear in inbox2 within a couple of seconds.
2. **Reply** from inbox2 and confirm it arrives.
3. **Comment** on a Page post or Instagram media → it shows up under Comments; you can
   hide or delete it from inbox2.

While your app is in **development mode**, the messaging APIs only return data for people
who have a **role on the app** (admin/developer/tester) — real customers come back empty
or with errors (e.g. Instagram `(#3) Application does not have the capability…`, or
Messenger/IG contacts showing a numeric id instead of a name). To serve the public you
need **Advanced Access** on the relevant permissions — and that's **per permission**, not
just flipping the app to Live.

**Request Advanced Access (use-case dashboard):**

1. Left sidebar → **Use cases** → **Customize** on the use case.
2. In the *Customize use case* left sub-menu, click **Permissions and features**.
3. Each permission shows a status and an **Actions ▾** menu. **"Ready for testing"** means
   it's at **Standard Access** — usable only by people with an app role (admin/developer/
   tester), not the public. The request to upgrade lives under **Actions ▾ → Request
   advanced access**.

   Two gotchas if you don't see / can't click it:
   - **The call counter must be > 0.** Meta keeps *Request advanced access* disabled until
     you've made **≥1 successful API call** with that permission (it shows up within ~2
     days). This is a catch-22 for Instagram messaging: `instagram_business_manage_messages`
     may return `(#3) … capability` until it's advanced, so it never logs a successful
     call — contact Meta support / check **Requirements** if it stays stuck at 0.
   - **Business Verification is required** (Business Settings → **Security Center**) before
     Advanced Access is granted.

   Request advanced access for **exactly the permissions inbox2 uses** — nothing more
   (each extra permission needs its own justification and slows review):

   - **WhatsApp:** `whatsapp_business_messaging`, `whatsapp_business_management`
   - **Messenger/Pages:** `pages_messaging`, `pages_show_list`, `pages_manage_metadata`,
     `pages_read_engagement`, `pages_manage_engagement`, `business_management`
   - **Instagram (Instagram-Login path):** `instagram_business_basic`,
     `instagram_business_manage_messages`, `instagram_business_manage_comments`

   > **Don't submit the classic Instagram scopes.** Because inbox2 uses **Instagram
   > Login**, the Instagram permissions are the `instagram_business_*` ones above — *not*
   > `instagram_basic` / `instagram_manage_messages` / `instagram_manage_comments` (those
   > belong to the older Facebook-Login Instagram path). And Instagram does **not** need
   > the Page or `business_management` scopes — those are only for Messenger. If your app
   > still lists the classic `instagram_*` permissions from an earlier setup, you can leave
   > them un-requested; they aren't used. `instagram_business_content_publish` and
   > `instagram_business_manage_insights` are also unused — skip them.
   >
   > The Instagram permissions are requested from the **Instagram** use case (the same
   > *Permissions and features* dashboard, under the Instagram product), not the Facebook
   > Login one.
4. Advanced Access also requires an **App Review** submission — a screencast + a written
   justification per permission describing how inbox2 uses it.
5. Once granted, **switch the app to Live** (toggle at the top of the App Dashboard).

> No reconnect needed afterward: inbox2 keeps retrying the backfill each sync, so the
> first sync after access is granted pulls the threads (watch the log for the
> `(#3) … capability` error to disappear).

> **Older app layout:** apps *not* created from use cases expose this at the top-level
> **App Review → Permissions and Features** instead — same per-permission **Get advanced
> access** buttons.

> **WhatsApp 24-hour rule:** outside 24 hours of a customer's last message you can only
> send an **approved message template** (create templates in WhatsApp Manager). Within
> the 24-hour window you can send free-form text. inbox2 handles this for you in compose.

---

## If your number or Page is already connected to another tool

A WhatsApp number or Facebook Page can be used by more than one app at the same time —
Meta delivers each message to **every** connected app. So you can add inbox2 **alongside**
an existing integration:

- **Use a separate Meta app for inbox2** (the one you created above) with its own secret
  and token.
- **Don't change the other tool's settings or webhook** — just connect inbox2 normally.
  Both keep working.

⚠️ If it's a **live** number with real customers, connecting it to inbox2 means those real
messages also flow into inbox2 — it isn't a sandbox. For a clean trial, use a **dedicated
test number / Page** instead.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| **"Couldn't auto-detect…"** when connecting | The token is missing a permission, or the asset isn't assigned to the system user. Re-check Step 4 (scopes) and Step 5 (assign with full control). |
| **Instagram "(#3) Application does not have the capability to make this API call"** | The app lacks **Advanced Access** for the Instagram messaging permissions (going Live isn't enough). Request it per-permission under **Use cases → Customize → Permissions and features → Get advanced access** for `instagram_business_manage_messages` / `instagram_business_manage_comments` / `instagram_business_basic` (the Instagram-Login scopes — not the classic `instagram_*` ones), and confirm the Instagram product has messaging enabled (Step 8). |
| **"Insufficient developer role"** when adding an Instagram account | While the app is in development mode the IG account needs the **Instagram Tester** role: App Dashboard → **App roles → Roles** → **Instagram Testers** → add the username, then **accept the invite** as that account at **instagram.com/accounts/manage_access/** → *Tester Invites* tab (phone: **Settings and privacy → Apps and websites → Tester Invites**) (Step 2). The role shows **Pending** until accepted. |
| **Connect succeeds but nothing arrives** | The app secret you entered doesn't match the app's real secret — re-copy it from Step 3. |
| **"Webhook configuration failed"** | The app lacks the product/permission for that channel, or it still needs App Review. Add the product (Step 2) and finish App Review (Step 8). |
| **WhatsApp reply fails (error 131047 / 131051)** | No open 24-hour window — send an approved **template** instead. |
| **Send fails with error 190** | The token is invalid or was regenerated — generate a new one (Step 4) and reconnect. |
| **Send fails with error 100** | Wrong asset ID — double-check the WABA ID / Page ID from Step 6. |
| **Messenger/Instagram contacts show a numeric id, no name/photo** | inbox2 resolves names + avatars via the profile API using the channel's scopes (`pages_messaging` for Messenger; `instagram_business_basic` + `instagram_business_manage_messages` for Instagram). While the app is in **development mode** this resolves only for people with an app role; for everyone else it needs **App Review / Advanced Access** (Step 8). WhatsApp has no profile-photo API — names come from the message itself. |
