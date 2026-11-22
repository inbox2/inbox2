Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Web Bot Auth key directory (Cloudflare Verified Bots) — public, signed JWKS
  # advertising the image proxy's Ed25519 signing key. 404 until the key is set.
  get "/.well-known/http-message-signatures-directory",
      to: "well_known#http_message_signatures_directory"

  # MTA-STS policy (RFC 8461). Senders fetch this over HTTPS at
  # mta-sts.<domain>/.well-known/mta-sts.txt to learn our TLS policy; the org is
  # resolved from the request Host. 404 when the domain has no enforced policy.
  get "/.well-known/mta-sts.txt", to: "well_known#mta_sts"

  # Open-tracking pixel (docs/Open-Tracking.md) — public, no auth. Served on the
  # inbox2 default host and on customer custom hosts (track.*, via CF-for-SaaS).
  # The `.gif` suffix is a literal (tokens are dot-free URL-safe nanoids); `:token`
  # is the capability.
  get "/o/:token.gif", to: "pixel#show"

  # Open-tracking click redirect (docs/Open-Tracking.md) — public, no auth. Records
  # the click, then 302s to the original URL.
  get "/l/:token", to: "link#show"

  # Desktop app distribution (bundles in the Pushleft bucket, docs/Desktop-Release.md).
  # The updater manifest is served with a short cache; binaries redirect to a
  # presigned bucket GET. The /api/v1 list feeds the /console download card.
  get "/downloads/desktop/latest.json", to: "desktop_releases#manifest"
  get "/downloads/desktop/:version/:file", to: "desktop_releases#file",
      constraints: { version: /\d+\.\d+\.\d+[^\/]*/, file: /[^\/]+/ }, format: false
  get "/api/v1/desktop/releases/latest", to: "desktop_releases#latest"

  # Pushleft App admin (docs/SaaS.md): the operator back office, called by the
  # Pushleft console with a request-bound token. Every path under the prefix
  # goes to this controller, so none of them answers without that token.
  scope "/_pushleft/admin", controller: "pushleft_admin", format: false do
    get   "schema",        action: :schema
    get   "overview",      action: :overview
    get   ":resource",     action: :index
    get   ":resource/:id", action: :show
    patch ":resource/:id", action: :update
    post  ":resource/:id/actions/:action_name", action: :run_action
    match "(*path)", action: :not_found, via: :all
  end

  namespace :api do
    namespace :v1 do
      # A1. Auth — spec 2.1
      post "auth/signup", to: "auth#signup"
      post "auth/login", to: "auth#login"
      post "auth/logout", to: "auth#logout"
      post "auth/password/reset-request", to: "auth#reset_password_request"
      post "auth/password/reset", to: "auth#reset_password"
      post "auth/confirm-email", to: "auth#confirm_email"
      get "auth/sessions", to: "auth#sessions"
      delete "auth/sessions", to: "auth#destroy_all_sessions"

      # Device-link (loopback + PKCE) — link a desktop/mobile client to an account
      # without pasting a key. `authorize` is session-authed (web approval page);
      # `token` is public (the native client proves itself with the PKCE verifier).
      # See docs/Device-Link.md.
      post "auth/device-link/authorize", to: "device_link#authorize"
      post "auth/device-link/token", to: "device_link#token"

      # Waitlist — public pre-launch interest form (invite-only gate). Bot-gated
      # by Cloudflare Turnstile; deduped without leaking existence. Operators
      # invite from the SaaS surface. See the waitlist plan + docs/SaaS.md.
      # Public meet-link scheduler (docs/Calendar.md): busy/free + meeting
      # requests, capability-URL-gated, no auth.
      # Disk public links (docs/plans/disk-build.md section 7): unauthenticated,
      # token-gated, rate limited in config/initializers/rack_attack.rb.
      get "disk/links/:token", to: "disk/public_links#show"
      post "disk/links/:token/unlock", to: "disk/public_links#unlock"
      get "disk/links/:token/download", to: "disk/public_links#download"
      # Disk importers: the provider's redirect after consent (signed state).
      get "disk/imports/:provider/callback", to: "disk/imports#callback"
      get "meet/:token", to: "meet#show"
      get "meet/:token/availability", to: "meet#availability"
      post "meet/:token/requests", to: "meet#create_request"
      # Google/Microsoft redirect for conferencing connections (signed state).
      get "conferencing/:provider/callback", to: "conferencing#callback"

      post "waitlist", to: "waitlist#create"
      get "waitlist/config", to: "waitlist#public_config"
      get "waitlist/invite", to: "waitlist#invite_lookup"

      # A2. Account — spec 2.2
      get "account", to: "accounts#show"
      patch "account", to: "accounts#update"
      put "account/billing-email", to: "accounts#update_billing_email"
      put "account/password", to: "accounts#update_password"
      post "account/avatar", to: "accounts#upload_avatar"
      get "account/avatar/:token", to: "accounts#avatar"

      # Weather — public utility feeding the Bridge morning brief (IP-based). Not
      # org-scoped; exposes no tenant data.
      get "weather", to: "weather#show"

      # Touch Strip — public market/weather/news/IP feeds (throttled per IP) and
      # the user's synced strip layout. docs/Touch-Strip.md
      get "strip/quotes", to: "strip#quotes"
      get "strip/symbols", to: "strip#symbols"
      get "strip/places", to: "strip#places"
      get "strip/weather", to: "strip#weather"
      get "strip/ip", to: "strip#ip"
      get "strip/news", to: "strip#news"
      get "account/touch-strip", to: "strip#show_config"
      put "account/touch-strip", to: "strip#update_config"
      get "account/lore-auto", to: "lore_auto#show"
      put "account/lore-auto", to: "lore_auto#update"

      # A3. Organizations — spec 2.2, 2.3
      resources :orgs, param: :org_id, controller: "organizations", only: %i[create show update destroy] do
        member do
          get "dns", to: "dns#show"
          post "dns/verify", to: "dns#verify"
          post "dns/cloudflare", to: "dns#cloudflare"
          post "test-email", to: "organizations#test_email"
          post "icon", to: "organizations#upload_icon"
          post "icon/fetch", to: "organizations#fetch_icon"
          post "logo", to: "organizations#upload_logo"
          # Public, unauthenticated: brand assets are shown in <img> tags without
          # a bearer token (workspace tab, emails, pre-auth login co-brand). 302s
          # to a short-lived presigned URL so the object never needs to be public.
          get "brand/:kind", to: "organizations#brand", constraints: { kind: /icon|logo/ }
          get "onboarding", to: "organizations#onboarding"
        end
      end

      # Org-scoped resources
      scope "orgs/:org_id" do
        # Mailbox stats — Command Center
        get "mailboxes/stats", to: "mailboxes#stats"
        get "mailboxes/graph", to: "mailboxes#graph"
        get "mailboxes/pair", to: "mailboxes#pair"

        # A4. Members — spec 5.1 (invites go through the top-level /members/invite-mx)
        resources :members, controller: "members", only: %i[index update destroy] do
          # Team activity board: org-wide summary + per-member action feed.
          collection { get "activity", to: "member_activity#index" }
          member do
            get "activity", to: "member_activity#show"
            # Re-send the invite email to a still-pending (`invited`) member.
            post "resend-invite", to: "members#resend_invite"
          end
        end

        # A9. Tags — spec 6.2
        resources :tags, controller: "tags", only: %i[index create update destroy] do
          member { post :share }
        end

        # Registered applications (console → Applications) — docs/App-OAuth.md.
        resources :oauth_apps, path: "oauth-apps", controller: "oauth_apps",
                               only: %i[index show create update destroy] do
          member { post "icon", to: "oauth_apps#upload_icon" }
        end

        # A6. Conversations — spec 3.1, 3.4, 4.2
        resources :conversations, controller: "conversations", only: %i[index show update] do
          collection do
            post "bulk", to: "conversations#bulk"
            post "empty", to: "conversations#empty"
            get "unread-count", to: "conversations#unread_count"
          end
          member do
            put "tags", to: "conversations#update_tags"
            put "space", to: "conversations#update_space"
            # Manual triage (docs/Triage.md): pick a label, or ask Jev again.
            put "triage-label", to: "conversations#update_triage_label"
            post "retriage", to: "conversations#retriage"
            post "archive", to: "conversations#archive"
            post "trash", to: "conversations#trash"
            post "spam", to: "conversations#spam"
            get "raw/:message_id", to: "conversations#raw", as: :raw
            # A8. Assignment & Access — spec 5.2, 5.3
            put "assignees", to: "assignment#update_assignees"
            delete "assignees/:member_id", to: "assignment#remove_assignee", as: :remove_assignee
            put "access", to: "assignment#update_access"
            delete "access/:member_id", to: "assignment#remove_access", as: :remove_access
            # A12. Notes — spec 9.1
            post "notes", to: "notes#create"
            patch "notes/:note_id", to: "notes#update", as: :update_note
            delete "notes/:note_id", to: "notes#destroy", as: :destroy_note
            post "notes/:note_id/reactions", to: "notes#add_reaction", as: :note_reaction
            delete "notes/:note_id/reactions", to: "notes#remove_reaction", as: :remove_note_reaction
            # A15.2 Spam feedback
            post "spam-feedback", to: "conversations#spam_feedback"
            # Advanced conversation actions (P1)
            post "snooze", to: "conversations#snooze"
            delete "snooze", to: "conversations#unsnooze"
            post "merge", to: "conversations#merge"
            post "split", to: "conversations#split"
            get "activity", to: "org_management#activity"
          end
        end

        # A7. Messages & Attachments — spec 4.2, 8.1
        resources :messages, controller: "messages", only: %i[create]
        resources :attachments, controller: "attachments", only: %i[show create destroy]

        # A10. Views — spec 3.2, 3.3
        resources :views, controller: "views", only: %i[index create update destroy] do
          member do
            post "share", to: "views#share"
          end
        end
        put "settings/view-policy", to: "views#update_policy"
        get "views/counts", to: "views#counts"
        get "views/suggestions", to: "views#suggestions"
        post "search/save", to: "views#save_search"

        # Spaces — org-defined MX classification buckets (treemap dashboard)
        resources :spaces, controller: "spaces", only: %i[index create update destroy]
        # Jev triage action labels — built-ins + org custom (docs/Triage.md)
        resources :triage_labels, path: "triage-labels", controller: "triage_labels", only: %i[index create update destroy]
        # Address folders — Inbox, own/tag/shared address folders (AddressFolders)
        get "folders", to: "folders#index"
        patch "folders/prefs", to: "folders#prefs"
        # Lore ontology — mined entities, facts and the entity graph (docs/Ontology.md)
        get "lore/entities", to: "lore#entities"
        get "lore/entities/:id", to: "lore#entity"
        patch "lore/entities/:id", to: "lore#update_entity"
        delete "lore/entities/:id", to: "lore#destroy_entity"
        post "lore/entities/:id/merge", to: "lore#merge_entity"
        patch "lore/entities/:id/facts/:fact_id", to: "lore#update_fact"
        delete "lore/entities/:id/facts/:fact_id", to: "lore#destroy_fact"
        get "lore/graph", to: "lore#graph"

        # Admin console aggregate stats (/admin dashboard)
        get "admin/overview", to: "admin#overview"

        # A16. Billing — org-scoped (subscription belongs to the org)
        get "billing", to: "billing#show"
        post "billing/subscribe", to: "billing#subscribe"
        get "billing/invoices", to: "billing#invoices"
        put "billing/payment-method", to: "billing#update_payment_method"

        # Domains (first-class; an org owns many) — spec 2.3
        get "e2ee/my-grants", to: "domain_keys#mine"
        resources :domains, controller: "domains", only: %i[index show create destroy] do
          member do
            get "dns", to: "domains#dns"
            # The domain's shared addresses (info@, support@): the address folders' list.
            get "shared-addresses", to: "domains#shared_addresses"
            put "shared-addresses", to: "domains#update_shared_addresses"
            post "dns/verify", to: "domains#verify"
            # One-click DNS setup: write the required records into the domain's
            # Cloudflare zone with a customer API token, then re-verify.
            post "dns/cloudflare", to: "domains#configure_cloudflare"
            # Open tracking (docs/Open-Tracking.md): settings + custom tracking-host
            # DNS/cert setup + verify.
            get "tracking", to: "domains#tracking"
            patch "tracking", to: "domains#update_tracking"
            post "tracking/verify", to: "domains#verify_tracking"
            # Per-domain square icon: authed upload + public streaming (shown in
            # <img> tags on the workspace tab without a bearer token).
            post "icon", to: "domains#upload_icon"
            get "brand/icon", to: "domains#brand"
            # E2EE key provisioning + per-domain switch — docs/E2EE.md Phase B
            get "e2ee", to: "domain_keys#show"
            put "e2ee", to: "domain_keys#update"
            post "e2ee/keys", to: "domain_keys#create"
            post "e2ee/grants", to: "domain_keys#create_grant"
          end
        end

        # Mailboxes (member × domain addresses)
        resources :mailboxes, controller: "mailboxes_crud", only: %i[index create destroy]

        # A7.5-A7.6 Send later / undo send
        post "messages/:id/schedule", to: "messages#schedule"
        post "messages/:id/cancel-send", to: "messages#cancel_send"
        # Meeting-invite RSVP (docs/Meeting-Invites.md)
        post "messages/:id/rsvp", to: "messages#rsvp"
        post "messages/:id/calendar-import", to: "messages#calendar_import"

        # MX sync — the clients' local mirror (docs/MX-Sync.md, spec 16.7)
        get "sync/head", to: "sync#head"
        get "sync/pull", to: "sync#pull"
        get "sync/backfill", to: "sync#backfill"
        get "sync/keys", to: "sync#keys"
        get "sync/threads", to: "sync#threads"

        # Mail import from Google Workspace / Microsoft 365 (docs/plans/mail-import.md)
        get "mail-imports", to: "mail_imports#index"
        post "mail-imports", to: "mail_imports#create"
        post "mail-imports/:id/resume", to: "mail_imports#resume"
        delete "mail-imports/:id", to: "mail_imports#destroy"
        # A person's own .mbox, picked in Settings › Account
        get "my-mail-imports", to: "my_mail_imports#index"
        post "my-mail-imports", to: "my_mail_imports#create"
        post "my-mail-imports/:id/resume", to: "my_mail_imports#resume"
        delete "my-mail-imports/:id", to: "my_mail_imports#destroy"

        # A15.4 IMAP Import
        post "import/imap", to: "data#imap_import"
        post "import/imap/test", to: "data#imap_test"

        # A15.6-A15.7 Data & GDPR
        post "export", to: "data#export"
        get "exports", to: "data#exports"
        get "exports/:id/download", to: "data#export_download"
        post "gdpr/contact-request", to: "data#gdpr_export"
        delete "gdpr/contact-request", to: "data#gdpr_delete"

        # A11. Routing Rules — spec 7
        resources :rules, controller: "rules", only: %i[index create update destroy] do
          collection do
            put "order", to: "rules#reorder"
            post "preview", to: "rules#preview"
          end
          member do
            patch "toggle", to: "rules#toggle"
            get "run-log", to: "rules#run_log"
            post "dry-run", to: "rules#dry_run"
            post "apply-existing", to: "rules#apply_existing"
          end
        end

        # A5. Agents — spec 5.5
        resources :agents, controller: "agents", only: %i[index show create update destroy] do
          member do
            post "credentials", to: "agents#credentials"
            get "feed", to: "agents#feed"
            get "run-logs", to: "agents#run_logs"
          end
          collection do
            get "approval-queue", to: "agents#approval_queue"
          end
        end

        # A17.3 MCP server — spec 14.3
        get "mcp/tools", to: "mcp#tools"
        post "mcp/execute", to: "mcp#execute"

        # Mail clients (docs/Mail-Clients.md) — spec 22.1: a member's own app
        # passwords and the settings a mail client needs.
        get "mail-client", to: "mail_client_passwords#settings"
        resources :mail_client_passwords, only: %i[index create destroy], path: "mail-client/passwords"

        # The ESP, console side (docs/ESP.md) — spec 21.2
        scope "esp", module: "esp_admin", as: "esp_admin" do
          resources :keys, only: %i[index create destroy]
          resources :domains, only: %i[index create destroy] do
            post "verify", on: :member
          end
          resources :emails, only: %i[index show]
          get "usage", to: "emails#usage"
        end

        # A11.6 Webhooks — spec 7.3.5
        resources :webhooks, controller: "webhooks", only: %i[index create update destroy]

        # A15. Spam & Security — spec 11
        resources :mail_filters, controller: "mail_filters", only: %i[index create destroy], path: "filters"
        get "audit-log", to: "audit_logs#index"

        # A10.6 Search — spec 6.3
        get "search", to: "search#index"

        # A7.4 Drafts — spec 8.1.5
        resources :drafts, controller: "drafts", only: %i[index create update destroy]

        # A18. Delivery Channels — spec 20
        resources :delivery_channels, controller: "delivery_channels", only: %i[index show create update destroy], path: "delivery-channels" do
          collection do
            put "set-default", to: "delivery_channels#set_default"
          end
          member do
            post "test", to: "delivery_channels#test"
            get "stats", to: "delivery_channels#stats"
          end
        end
        get "delivery-log", to: "delivery_channels#delivery_log"
        get "conversations/:conversation_id/messages/:message_id/delivery", to: "delivery_channels#message_delivery"

        # A18.11 Deliverability — choose inbox2 SMTP vs a customer-owned ESP (spec 20.3)
        get "deliverability", to: "deliverability#show"
        put "deliverability", to: "deliverability#update"
        post "deliverability/test", to: "deliverability#test"
        # TODO 46.10 — received TLS-RPT / DMARC rua aggregate reports
        get "deliverability/auth-reports", to: "deliverability#auth_reports"

        # A3.8 Alias domains (P1)

        # A3.9 Domain health (P1)

        # A3.4 Delete org (P1)

        # A3.10 Transfer ownership (P1)
        post "transfer-ownership", to: "org_management#transfer_ownership"

        # A13.1 Templates (P1)
        resources :templates, controller: "templates", only: %i[index create update destroy]

        # SAML config — spec 2.1.7
        get "saml", to: "saml#show"
        put "saml", to: "saml#configure"
        delete "saml", to: "saml#destroy"

        # Embeddable widgets — spec 14.7
        resources :widgets, controller: "widgets", only: %i[index create update destroy]

        # Integrations — spec 14.6
        resources :integrations, controller: "integrations", only: %i[index show create update destroy]

        # A21. Calendar — spec 21
        resources :calendars, controller: "calendars", only: %i[index show create update destroy]

        resources :events, controller: "calendar_events", only: %i[index show create update destroy], path: "events" do
          member do
            post "rsvp", to: "calendar_events#rsvp"
            post "propose-time", to: "calendar_events#propose_time"
            # Organizer answering a counter-proposal (docs/Calendar.md).
            post "accept-proposal", to: "calendar_events#accept_proposal"
            post "decline-proposal", to: "calendar_events#decline_proposal"
          end
          collection do
            get "free-busy", to: "calendar_events#free_busy"
            # Scheduling assistant — busy blocks + working hours + ranked slots
            # for a set of attendees (docs/Calendar.md).
            get "availability", to: "calendar_events#availability"
            # The org's own addresses, for the colleague picker.
            get "directory", to: "calendar_events#directory"
            post "from-ics", to: "calendar_events#create_from_ics"
          end
        end

        # Meet links + blocked time + request decisions (docs/Calendar.md)
        resources :meet_links, controller: "meet_links", only: %i[index create destroy], path: "meet-links"
        resources :blocked_times, controller: "blocked_times", only: %i[index create destroy], path: "blocked-times"
        # Busy-only blocks uploaded from devices' local calendars
        put "external-busy", to: "external_busy#update"
        post "meeting-requests/:id/accept", to: "meeting_requests#accept"
        post "meeting-requests/:id/decline", to: "meeting_requests#decline"
        get "conferencing", to: "conferencing#index"
        post "conferencing/:provider/connect", to: "conferencing#connect"
        delete "conferencing/:provider", to: "conferencing#destroy"

        # A13.2 Signatures (P1)
        resources :signatures, controller: "signatures", only: %i[index create update destroy]

        # Disk mail integration (spec F9), MX mail only
        post "messages/:message_id/attachments/:attachment_id/save-to-disk", to: "disk/mail#save"
        post "messages/:message_id/attachments/from-disk", to: "disk/mail#attach"

        # Disk: file storage (docs/plans/disk-build.md section 7)
        scope "disk", module: "disk", as: "disk" do
          get "/", to: "drives#show"
          resources :shares, only: %i[index create update destroy] do
            member do
              post :restore
              delete :purge
            end
            post :templates, on: :collection
            resources :members, controller: "share_members", only: %i[index update destroy], param: :membership_id
          end
          post "nodes/bulk", to: "nodes#bulk"
          resources :nodes, only: %i[show create update destroy] do
            member do
              get :children
              post :move
              post :copy
              post :switch
              post :restore
              delete :purge
              get :events
              get :download
              get :tree
              get :versions, to: "versions#index"
              post "preview-failures", action: :preview_failures
            end
            resources :grants, only: %i[index update destroy], param: :membership_id
            resources :links, only: %i[index create]
          end
          resources :links, only: :destroy
          resources :pages, only: %i[show update], param: :node_id do
            member do
              get :versions
              get "versions/:revision", action: :version, as: :version
              post :updates
            end
          end
          # Sealed scopes and member keys (build guide 6.7)
          get "scopes/:node_id", to: "scopes#show"
          post "scopes/:node_id/rotate", to: "scopes#rotate"
          post "scopes/:node_id/transfer", to: "scopes#transfer"
          get "keys/members", to: "keys#members"
          resources :uploads, only: %i[create show destroy] do
            member do
              post :parts
              post :complete
            end
          end
          resources :versions, only: [] do
            member do
              get :download
              post :restore
              put :thumbnail
              put :rendition
            end
          end
          get "search", to: "search#index"
          get "views/shared-with-me", to: "views#shared_with_me"
          get "views/recent", to: "views#recent"
          get "views/starred", to: "views#starred"
          get "views/trash", to: "views#trash"
          # Agents (build guide 9c): MCP endpoint and the grants that scope it.
          post "mcp", to: "mcp#create"
          match "mcp", to: "mcp#not_allowed", via: %i[get delete]
          get "agents/:agent_id/grants", to: "agent_grants#index"
          put "agents/:agent_id/grants/:node_id", to: "agent_grants#update"
          delete "agents/:agent_id/grants/:node_id", to: "agent_grants#destroy"
          # Console (spec F11)
          get "admin/usage", to: "admin#usage"
          get "admin/links", to: "admin#links"
          get "admin/events", to: "admin#events"
          delete "admin/links/:id", to: "admin#revoke_link"
          put "admin/settings", to: "admin#settings"
          get "admin/export", to: "admin#export"
          # Importers (spec F10, build guide 9b)
          get "imports/sources", to: "imports#sources"
          post "imports/:provider/connect", to: "imports#connect"
          delete "imports/:provider/connection", to: "imports#disconnect"
          get "imports", to: "imports#index"
          post "imports", to: "imports#create"
          get "imports/:id", to: "imports#show"
          post "imports/:id/resume", to: "imports#resume"
          delete "imports/:id", to: "imports#destroy"
          get "imports/:id/report", to: "imports#report"
        end
      end

      # A2.4 Organization list (P1)
      get "account/organizations", to: "org_management#list_orgs"

      # Mail clients (docs/Mail-Clients.md) — spec 22.2: what the IMAP and SMTP
      # frontend (mta/cmd/imap) calls, signed in with a person's app password.
      scope "mail-client", controller: "mail_client" do
        get "session", action: :session_info
        get "folders", action: :folders
        post "submit", action: :submit
        scope "folders/:folder" do
          get "messages", action: :messages
          get "messages/:uid/header", action: :header
          get "messages/:uid/raw", action: :raw
          post "flags", action: :flags
          post "move", action: :move
          post "expunge", action: :expunge
          post "search", action: :search
          post "append", action: :append
        end
      end

      # The ESP, application side: authenticated by an org sending key (isk_…),
      # not a user (docs/ESP.md) — spec 21.1
      scope "esp", module: "esp_api", as: "esp" do
        resources :emails, only: %i[index show create]
      end

      # A17.1 API Keys (P1)
      resources :api_keys, controller: "api_keys", only: %i[index create destroy], path: "account/api-keys"
      # Calendar zones (docs/Calendar.md "Zones") — user-scoped soft focus blocks.
      resources :zones, controller: "zones", only: %i[index create update destroy], path: "account/zones"
      resources :zone_categories, controller: "zone_categories", only: %i[index create update destroy], path: "account/zone-categories"
      resources :zone_dismissals, controller: "zone_dismissals", only: %i[index create], path: "account/zone-dismissals"

      # List-Unsubscribe one-click (spec 18.4.2)
      post "unsubscribe/:token", to: "unsubscribe#process_unsubscribe"

      # A1.11 SAML SSO (P2)
      get "orgs/:org_id/saml/initiate", to: "saml#initiate"
      post "orgs/:org_id/saml/consume", to: "saml#consume"
      get "orgs/:org_id/saml/metadata", to: "saml#metadata"
      # Signed-in member binds / inspects / drops their own IdP identity.
      get "orgs/:org_id/saml/identity", to: "saml#identity"
      post "orgs/:org_id/saml/link", to: "saml#link"
      delete "orgs/:org_id/saml/identity", to: "saml#unlink"
      # Browser lands here from the ACS redirect and trades the one-time ticket for a session.
      post "auth/saml/exchange", to: "saml#exchange"

      # A1.10 Social/SSO (P1)
      get "auth/oauth/providers", to: "oauth#providers"
      post "auth/oauth/callback", to: "oauth#callback"
      get "auth/oauth/identities", to: "oauth#index"
      delete "auth/oauth/identities/:provider", to: "oauth#destroy"

      # Google OAuth proxy — keeps client_id/secret server-side
      get  "auth/google/authorize", to: "google_oauth_proxy#authorize"
      post "auth/google/token",     to: "google_oauth_proxy#exchange"
      post "auth/google/refresh",   to: "google_oauth_proxy#refresh"

      # Microsoft OAuth proxy — keeps client_id/secret server-side
      get  "auth/microsoft/authorize", to: "microsoft_oauth_proxy#authorize"
      post "auth/microsoft/token",     to: "microsoft_oauth_proxy#exchange"
      post "auth/microsoft/refresh",   to: "microsoft_oauth_proxy#refresh"

      # Brokered provider OAuth for a registered third-party application
      # (docs/App-OAuth.md). `authorize`/`token` are the app's server with an
      # inbox2 API key; the rest are browser legs with no inbox2 credentials —
      # the consent screen, its Continue/Not-now buttons, and the provider's
      # redirect back.
      post "auth/app-oauth/authorize", to: "app_oauth#authorize"
      post "auth/app-oauth/token",     to: "app_oauth#token"
      post "auth/app-oauth/refresh",   to: "app_oauth#refresh"
      get  "auth/app-oauth/consent",   to: "app_oauth#consent"
      get  "auth/app-oauth/start",     to: "app_oauth#start"
      get  "auth/app-oauth/cancel",    to: "app_oauth#cancel"
      get  "auth/app-oauth/callback",  to: "app_oauth#callback"
      # Public: the consent screen renders the app's icon with no session.
      get  "oauth/apps/:app_id/icon",  to: "oauth_apps#icon"

      # A1.9 WebAuthn/Passkey (P1)
      post "auth/webauthn/registration-options", to: "webauthn#registration_options"
      post "auth/webauthn/register", to: "webauthn#register"
      get "auth/webauthn/authenticate-options", to: "webauthn#authenticate_options"
      post "auth/webauthn/authenticate", to: "webauthn#authenticate"
      get "auth/webauthn/credentials", to: "webauthn#index"
      delete "auth/webauthn/credentials/:id", to: "webauthn#destroy"
      put "auth/webauthn/requirement", to: "webauthn#requirement"

      # A1.8 TOTP 2FA (P1)
      post "auth/2fa/totp/enroll", to: "totp#enroll"
      post "auth/2fa/totp/verify", to: "totp#verify"
      delete "auth/2fa/totp", to: "totp#disable"

      # Image proxy — fetch remote email images server-side (privacy; spec 4.1.2)
      get "image-proxy", to: "image_proxy#show"

      # Brand lookup for a sender domain (docs/plans/lore.md §4b Imagery)
      get "brands/:domain", to: "brands#show", constraints: { domain: %r{[^/]+} }, format: false

      # A sender's picture: Gravatar, else their domain's icon (AvatarResolver)
      get "avatars", to: "avatars#show"

      # A14.4 Push subscriptions — spec 10.4
      post "push-subscriptions", to: "push_subscriptions#create"
      delete "push-subscriptions", to: "push_subscriptions#destroy"
      get "push-subscriptions/vapid", to: "push_subscriptions#vapid_public_key"

      # Cloud push for local channels (Gmail/Office365) — see docs/Cloud-Push.md
      resources :channel_push_subscriptions,
        controller: "channel_push_subscriptions",
        path: "channel-push-subscriptions",
        only: %i[index create update destroy] do
        collection do
          get "config", to: "channel_push_subscriptions#push_config"
        end
      end
      # E2EE identity keypair (per user, blob-only) — docs/E2EE.md Phase B.
      get "user-key", to: "user_keys#show"
      put "user-key", to: "user_keys#upsert"
      post "user-key/recovery-email", to: "user_keys#send_recovery_email"

      # Zero-knowledge cloud backup of channel credentials — see docs/E2EE.md.
      # Vault + upsert routes are declared before the resource so /stored-credentials/vault
      # isn't captured by the :id member route.
      put "stored-credentials", to: "stored_credentials#upsert"
      get "stored-credentials/vault", to: "stored_credentials#vault"
      put "stored-credentials/vault", to: "stored_credentials#upsert_vault"
      delete "stored-credentials/vault", to: "stored_credentials#destroy_vault"
      resources :stored_credentials,
        controller: "stored_credentials",
        path: "stored-credentials",
        only: %i[index show destroy]

      # Open-tracking opens poll for local channels (unauthenticated; token
      # capabilities). See docs/Open-Tracking.md.
      post "tracking/opens", to: "tracking#opens"
      # Per-channel custom tracking host: provision CF-for-SaaS TLS + verify DNS.
      post "tracking/register", to: "tracking#register"
      post "tracking/verify-host", to: "tracking#verify_host"
      # Cloud-synced per-channel open-tracking config (authenticated — mx session
      # or ink_ token). Local channels read/write here to sync across devices.
      get "tracking/channels", to: "tracking_channels#index"
      put "tracking/channels", to: "tracking_channels#upsert"

      # Provider webhook receivers (unauthenticated; verified per-provider)
      post "push/gmail", to: "push_webhooks#gmail"
      post "push/microsoft", to: "push_webhooks#microsoft"

      # Meta channels (Instagram/Messenger/WhatsApp) — see docs/Cloud-Push.md (Meta).
      # Device-reported asset→user routing (authenticated, idempotent upsert).
      resources :meta_channel_subscriptions,
        controller: "meta_channel_subscriptions",
        path: "meta-channel-subscriptions",
        only: %i[index create destroy] do
        collection do
          # Verify token + push gating, so the client can auto-configure the
          # customer app's webhook (POST /{app_id}/subscriptions) on connect.
          get "config", to: "meta_channel_subscriptions#meta_config"
        end
      end
      # Meta webhook receiver (unauthenticated): GET verify handshake (hub.challenge),
      # POST raw payload → buffer + nudge. Single URL for page/instagram/whatsapp.
      get "push/meta", to: "meta_webhooks#verify"
      post "push/meta", to: "meta_webhooks#receive"
      # Device fetch + ack of buffered raw payloads (authenticated, user-scoped).
      resources :meta_webhook_events,
        controller: "meta_webhook_events",
        path: "meta-webhook-events",
        only: %i[show destroy]

      # Instagram-Login OAuth bounce: Instagram requires an exact, HTTPS redirect
      # URI (no localhost-loopback), so the desktop registers this stable URL and
      # we 302 the code back to its local listener. Unauthenticated by design.
      get "oauth/instagram/callback", to: "instagram_oauth#callback"

      # Mobile push device tokens (APNs/FCM) — see docs/Cloud-Push.md "Mobile push"
      post "push-devices", to: "push_devices#create"
      post "push-devices/unread", to: "push_devices#unread"
      post "push-devices/live-activity", to: "push_devices#live_activity"
      post "push-devices/live-activity/start", to: "push_devices#live_activity_start"
      delete "push-devices", to: "push_devices#destroy"

      # A14. Notifications — spec 10
      get "notifications", to: "notifications#index"
      post "notifications/read", to: "notifications#mark_read"

      # Agency/reseller billing — spec 13.2.7
      get "agency", to: "agencies#show"
      post "agency", to: "agencies#create"
      patch "agency", to: "agencies#update"
      post "agency/organizations", to: "agencies#add_organization"
      delete "agency/organizations/:org_id", to: "agencies#remove_organization"
      get "agency/billing", to: "agencies#billing_summary"

      # Widget public config (no auth)
      get "widget/config/:token", to: "widgets#public_config"

      # A16. Plans — spec 13 (plan catalog is account-agnostic)
      get "plans", to: "plans#index"

      # A4. Accept invite (not org-scoped)
      post "members/accept-invite", to: "members#accept_invite"
      # Invite one person to private mailboxes across several of the inviter's domains.
      post "members/invite-mx", to: "members#invite_mx"

      # Cross-domain admin user management (spans every domain the admin manages).
      scope "admin" do
        get    "users",                 to: "admin_users#index"
        get    "users/:user_id",        to: "admin_users#show"
        post   "users/:user_id/assign", to: "admin_users#assign"
        delete "users/:user_id/assign", to: "admin_users#unassign"
        patch  "users/:user_id/status", to: "admin_users#update_status"
        delete "users/:user_id",        to: "admin_users#destroy"
      end

      # Platform SaaS (SaaS operations). Cross-tenant. In production this exists
      # only on the `operator` role, which has no public route: `pl tunnel` is the
      # way in. See docs/SaaS.md. The request can't influence this check.
      namespace :saas, constraints: ->(_req) { Rails.env.local? || ENV["SAAS_OPERATOR_PLANE"] == "1" } do
        get "dashboard", to: "dashboard#show"
        get "search", to: "search#index"

        resources :organizations, only: %i[index show create update] do
          member do
            post   :suspend
            post   :unsuspend
            delete :wipe
            get    :usage
            post   :plan
            post   :mailbox_limit
            post   :disk_quota
          end
          resources :members, only: %i[index create destroy]
        end

        resources :users, only: %i[index show] do
          member do
            post   :reset_password
            post   :disable
            post   :enable
            delete :offboard
          end
        end

        resources :waitlist_signups, only: %i[index show] do
          member do
            post :invite
          end
        end
      end
    end
  end
end
