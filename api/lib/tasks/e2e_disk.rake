# Seed for the Disk Playwright suite (ui/web/e2e/disk, `yarn e2e:disk`).
#
# Runs against a DEDICATED database and bucket that the harness creates fresh on
# every run (ui/web/e2e/disk/prepare.mjs): it refuses any database whose name does
# not contain "e2e", so it can never touch development data. It empties the e2e
# bucket, builds a small world of orgs, people, shares, folders, real files (the
# bytes go to Garage through Disk::UploadOps, the API's own write path), pages,
# links, an agent and one MX mail with an attachment, mints a session per person
# and writes everything the specs need to E2E_DISK_SEED_OUT as JSON.
#
#   E2E_DISK_SAMPLES=dir E2E_DISK_SEED_OUT=file bin/rails e2e:disk:seed
namespace :e2e do
  namespace :disk do
    desc "List the e2e bucket and say which objects contain any of MARKERS (comma separated), as JSON"
    task bucket_scan: :environment do
      storage = Disk::Storage.current
      abort "refuses bucket #{storage.bucket}" unless storage.bucket.include?("e2e")
      client = storage.instance_variable_get(:@client)
      markers = ENV.fetch("MARKERS").split(",")
      out = { objects: 0, keys: [], hits: markers.to_h { |m| [m, []] } }
      client.list_objects_v2(bucket: storage.bucket).each do |page|
        page.contents.each do |o|
          out[:objects] += 1
          out[:keys] << o.key
          # Every object, read in full up to 64 MB (the e2e files are small; the 38 MB video is the largest).
          body = client.get_object(bucket: storage.bucket, key: o.key, range: "bytes=0-#{64 * 1024 * 1024}").body.read
          markers.each { |m| out[:hits][m] << o.key if body.include?(m) }
        end
      end
      puts JSON.generate(out)
    end

    desc "Set an e2e import's columns from ATTRS (JSON), as the importer would while it runs"
    task import_update: :environment do
      db = ActiveRecord::Base.connection.current_database
      abort "refuses database #{db}" unless db.include?("e2e")
      Disk::Import.find_by!(key: ENV.fetch("IMPORT_ID")).update_columns(JSON.parse(ENV.fetch("ATTRS")).merge("updated_at" => Time.current))
    end

    desc "Move an e2e org's used Disk bytes by DELTA (fill it to the quota, then free it again), as uploads would"
    task org_bytes: :environment do
      db = ActiveRecord::Base.connection.current_database
      abort "refuses database #{db}" unless db.include?("e2e")
      org = Organization.find_by!(slug: ENV.fetch("ORG"))
      delta = ENV["DELTA"] == "fill" ? Disk::Quota.new(org).available_bytes : Integer(ENV.fetch("DELTA"))
      Disk::Quota.move!(org.id, used: delta)
      puts delta
    end

    desc "Make an e2e person (USER_NAME) an active member of another e2e org (ORG) too, for the multi-org tests"
    task join: :environment do
      db = ActiveRecord::Base.connection.current_database
      abort "refuses database #{db}" unless db.include?("e2e")
      user = User.find_by!(username: ENV.fetch("USER_NAME"))
      org = Organization.find_by!(slug: ENV.fetch("ORG"))
      Membership.find_or_create_by!(user: user, organization: org) do |m|
        m.role = Membership::ROLE_MEMBER
        m.status = Membership::STATUS_ACTIVE
      end
      puts org.key
    end

    desc "Mint a new session for an e2e person (USER_NAME) and print its token: signing it out ends only that session"
    task session: :environment do
      db = ActiveRecord::Base.connection.current_database
      abort "refuses database #{db}" unless db.include?("e2e")
      user = User.find_by!(username: ENV.fetch("USER_NAME"))
      puts user.sessions.create!(ip_address: "127.0.0.1", user_agent: "e2e", last_active_at: Time.current).raw_token
    end

    desc "Seed the Disk e2e database (refuses any database not named *e2e*)"
    task seed: :environment do
      db = ActiveRecord::Base.connection.current_database
      abort "e2e:disk:seed refuses database #{db}: its name must contain e2e" unless db.include?("e2e")
      samples = ENV.fetch("E2E_DISK_SAMPLES")
      out_path = ENV.fetch("E2E_DISK_SEED_OUT")
      password = "e2e-pass-123"

      storage = Disk::Storage.current
      abort "e2e:disk:seed refuses bucket #{storage.bucket}: its name must contain e2e" unless storage.bucket.include?("e2e")
      storage.setup!
      client = storage.instance_variable_get(:@client)
      client.list_objects_v2(bucket: storage.bucket).each do |page|
        keys = page.contents.map { |o| { key: o.key } }
        client.delete_objects(bucket: storage.bucket, delete: { objects: keys }) if keys.any?
      end

      Plan.seed_defaults!
      out = { password: password, orgs: {}, users: {}, nodes: {}, shares: {}, links: {} }

      user = lambda do |username, name, org, role|
        u = User.create!(username: username, password: password, display_name: name,
                         billing_email: "#{username}@e2e-disk.test")
        m = Membership.create!(user: u, organization: org, role: role, status: Membership::STATUS_ACTIVE)
        session = u.sessions.create!(ip_address: "127.0.0.1", user_agent: "e2e", last_active_at: Time.current)
        out[:users][username] = { id: u.key, name: name, membership_id: m.key, org: org.slug, token: session.raw_token }
        m
      end
      org_for = lambda do |slug, name, plan, owner_username, owner_name|
        owner = User.create!(username: owner_username, password: password, display_name: owner_name,
                             billing_email: "#{owner_username}@e2e-disk.test")
        org = Organization.create!(slug: slug, name: name, owner: owner, timezone: "UTC", plan: plan)
        m = Membership.create!(user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
        session = owner.sessions.create!(ip_address: "127.0.0.1", user_agent: "e2e", last_active_at: Time.current)
        out[:users][owner_username] = { id: owner.key, name: owner_name, membership_id: m.key, org: slug, token: session.raw_token }
        out[:orgs][slug] = { id: org.key, slug: slug, name: name }
        [org, m]
      end
      sample = ->(name) { File.binread(File.join(samples, name)) }
      put = lambda do |m, parent, name, bytes = sample.(name)|
        node, = Disk::UploadOps.new(m).write(bytes: bytes, parent_key: parent.key, name: name)
        node
      end
      folder = ->(m, parent, name) { Disk::NodeOps.new(m).create_folder(parent_key: parent.key, name: name) }
      page = lambda do |m, parent, name, markdown|
        node = Disk::NodeOps.new(m).create_folder(parent_key: parent.key, name: name, kind: Disk::Node::KIND_PAGE)
        Disk::Page.for(node).save_snapshot!(author: m, ydoc: nil, markdown: markdown, base_revision: 0)
        node
      end
      remember = ->(key, node) { out[:nodes][key] = { id: node.key, short_id: node.key.delete_prefix("dnd_"), name: node.name } }

      # ── Org A: the main org, on max, with everyone in it ────────────────────
      org, owner = org_for.("e2e-disk", "E2E Disk Co", Plan.max, "e2e_owner", "Olivia Owner")
      Domain.create!(name: "e2e-disk.test", organization: org, status: Domain::STATUS_VERIFIED)
      admin = user.("e2e_admin", "Adam Admin", org, Membership::ROLE_ADMIN)
      ana = user.("e2e_ana", "Ana Member", org, Membership::ROLE_MEMBER)
      ben = user.("e2e_ben", "Ben Member", org, Membership::ROLE_MEMBER)
      vic = user.("e2e_vic", "Vic Viewer", org, Membership::ROLE_MEMBER)
      user.("e2e_new", "Nina New", org, Membership::ROLE_MEMBER)
      leaver = user.("e2e_leaver", "Leo Leaver", org, Membership::ROLE_MEMBER)

      share = lambda do |name, icon, color, openness: Disk::Share::OPENNESS_ASSIGNED, org_role: Disk::ROLE_VIEW, members: {}|
        s = Disk::Share.create_with_root!(organization: org, name: name, icon: icon, color: color, openness: openness,
                                          org_role: org_role)
        members.each { |m, role| Disk::ShareMembership.create!(organization: org, share: s, membership: m, role: role) }
        out[:shares][name] = { id: s.key, slug: s.slug, root_id: s.root_node.key }
        s
      end
      marketing = share.("Marketing", "marketing", "#e06a3d",
                         members: { ana => Disk::ROLE_EDIT, ben => Disk::ROLE_MANAGE, vic => Disk::ROLE_VIEW })
      finance = share.("Finance", "finance", "#c98a1b", members: { admin => Disk::ROLE_MANAGE })
      everyone = share.("Handbook", "hr", "#8a5bd6", openness: Disk::Share::OPENNESS_ORG)

      mroot = marketing.root_node
      launch = folder.(ben, mroot, "Launch 2026")
      assets = folder.(ben, launch, "Assets")
      hero = folder.(ben, assets, "Hero")
      remember.(:launch, launch)
      remember.(:hero_folder, hero)
      remember.(:hero, put.(ben, hero, "hero-banner.png"))
      remember.(:launch_brief, put.(ben, launch, "brief.md"))

      # One file of every preview type, in one folder, for F5.
      samples_dir = folder.(ben, mroot, "Samples")
      remember.(:samples, samples_dir)
      %w[report.pdf photo.jpg diagram.svg clip.mp4 voice.m4a notes.md app.js page.html data.csv bundle.zip
         plan.docx budget.xlsx deck.pptx broken.pdf design.fig server.log].each do |f|
        remember.(:"sample_#{f.tr('.-', '__')}", put.(ben, samples_dir, f))
      end
      remember.(:launch_plan, page.(ben, mroot, "Launch plan",
                                    "# Launch plan\n\n## Goals\n\n- Ship Disk\n- Tell customers\n\n## To do\n\n- [ ] Write the post\n- [x] Book the venue\n\n| Week | Owner |\n| --- | --- |\n| 1 | Ana |\n\n```\necho launch\n```\n"))
      agent_zone = folder.(ben, mroot, "Agent Zone")
      remember.(:agent_zone, agent_zone)
      remember.(:agent_page, page.(ben, agent_zone, "Agent notes", "# Agent notes\n\nStarted by a person.\n"))
      remember.(:agent_md, put.(ben, agent_zone, "notes.md"))

      remember.(:finance_sheet, put.(admin, finance.root_node, "budget.xlsx"))
      remember.(:handbook, put.(owner, everyone.root_node, "report.pdf"))

      # The owner's C:\: a deep path, versions, a folder shared with Ana.
      oc = Disk::Node.c_root_for(owner)
      remember.(:owner_c, oc)
      deep = %w[Clients Acme 2026 Q1 Invoices].reduce(oc) { |p, n| folder.(owner, p, n) }
      remember.(:deep, deep)
      remember.(:deep_file, put.(owner, deep, "invoice-001.pdf", sample.("report.pdf")))
      versioned = put.(owner, oc, "contract.md", "# Contract v1\n")
      Disk::UploadOps.new(owner).write(bytes: "# Contract v2\n", node_key: versioned.key)
      Disk::UploadOps.new(owner).write(bytes: "# Contract v3\n", node_key: versioned.key)
      remember.(:contract, versioned)
      for_ana = folder.(owner, oc, "For Ana")
      remember.(:for_ana_sub, folder.(owner, for_ana, "Drafts"))
      put.(owner, for_ana, "welcome.md", "# Welcome Ana\n")
      Disk::NodeOps.new(owner).grant(for_ana, ana, Disk::ROLE_VIEW)
      remember.(:for_ana, for_ana)

      # Ana's C:\ and the leaver's.
      ac = Disk::Node.c_root_for(ana)
      remember.(:ana_c, ac)
      remember.(:ana_note, put.(ana, ac, "ana-notes.md", "# Ana's notes\n"))
      lc = Disk::Node.c_root_for(leaver)
      put.(leaver, folder.(leaver, lc, "Leo stuff"), "handover.md", "# Handover\n")

      # Public links on Marketing/Samples.
      ops = Disk::NodeOps.new(ben)
      link = lambda do |key, node, **opts|
        l, token = ops.create_link(node, **opts)
        out[:links][key] = { id: l.key, token: token, path: URI(Disk::WebPath.public_link(node, token)).path }
        l
      end
      pdf = Disk::Node.find_by!(key: out[:nodes][:sample_report_pdf][:id])
      link.(:open, pdf)
      link.(:password, pdf, password: "open-sesame")
      link.(:hidden, pdf, hide_download: true)
      link.(:expired, pdf).update_columns(expires_at: 1.day.ago)
      ops.revoke_link(link.(:revoked, pdf))
      link.(:folder, launch)

      # The agent: every Disk permission, edit on Agent Zone, a key.
      agent_user = User.create!(username: "agent_e2e", password: SecureRandom.hex(16), display_name: "E2E Agent")
      agent_m = Membership.create!(user: agent_user, organization: org, role: Membership::ROLE_MEMBER,
                                   status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_AGENT)
      agent = org.agents.create!(membership: agent_m, name: "E2E Agent", permissions: Agent::DISK_PERMISSIONS)
      Disk::AgentGrant.create!(organization: org, agent: agent, node: agent_zone, role: Disk::ROLE_EDIT, granted_by: ben)
      out[:agent] = { id: agent.key, name: agent.name, token: agent.generate_credential! }

      # One MX mail with an attachment (spec F9), its bytes in the attachments store.
      # team@ is a shared address the owner replies as, so the mail is in their
      # Inbox (address folders: Inbox = mail for you).
      mail_domain = Domain.find_by!(name: "e2e-disk.test")
      mail_domain.update!(shared_addresses: [{ "local_part" => "team" }])
      owner.update!(send_as_addresses: ["team@e2e-disk.test"])
      conv = Conversation.create!(organization: org, domain: mail_domain,
                                  subject: "Quarterly figures", from_address: "Carol Client <carol@client.test>",
                                  to_address: "team@e2e-disk.test", status: Conversation::STATUS_OPEN, read: false,
                                  snippet: "Figures attached")
      msg = Message.create!(conversation: conv, organization: org, from_address: "Carol Client <carol@client.test>",
                            to_address: "team@e2e-disk.test", subject: "Quarterly figures",
                            body_plain: "Hi team,\n\nThe figures are attached.\n\nCarol", is_inbound: true, is_draft: false,
                            message_id_header: "<e2e-figures@client.test>")
      csv = sample.("data.csv")
      key = S3StorageService.new.upload(csv, filename: "figures.csv", content_type: "text/csv", organization_key: org.key)
      att = Attachment.create!(message: msg, organization: org, filename: "figures.csv", content_type: "text/csv",
                               size_bytes: csv.bytesize, storage_key: key)
      out[:mail] = { conversation_id: conv.key, message_id: msg.key, attachment_id: att.key }

      # ── Org B: another tenant, for isolation ───────────────────────────────
      other, other_owner = org_for.("e2e-other", "Other Tenant", Plan.max, "e2e_other", "Otto Other")
      oroot = Disk::Node.c_root_for(other_owner)
      ofolder = folder.(other_owner, oroot, "Secret plans")
      remember.(:other_folder, ofolder)
      remember.(:other_file, put.(other_owner, ofolder, "secret.md", "# Not for you\n"))
      remember.(:other_page, page.(other_owner, oroot, "Other page", "# Theirs\n"))
      oshare = Disk::Share.create_with_root!(organization: other, name: "Other Share", openness: Disk::Share::OPENNESS_ORG,
                                             org_role: Disk::ROLE_VIEW)
      out[:shares]["Other Share"] = { id: oshare.key, slug: oshare.slug, root_id: oshare.root_node.key }
      ol, otoken = Disk::NodeOps.new(other_owner).create_link(Disk::Node.find_by!(key: out[:nodes][:other_file][:id]))
      out[:links][:other] = { id: ol.key, token: otoken, path: URI(Disk::WebPath.public_link(ol.node, otoken)).path }

      # ── Org C: a plan without Disk (paywall) ───────────────────────────────
      org_for.("e2e-nodisk", "No Disk Ltd", Plan.free, "e2e_free", "Fran Free")

      # ── Org D: downgraded two days ago (read-only) ─────────────────────────
      ro, ro_owner = org_for.("e2e-readonly", "Read Only Inc", Plan.max, "e2e_ro", "Rory Readonly")
      remember.(:ro_file, put.(ro_owner, Disk::Node.c_root_for(ro_owner), "kept.md", "# Still here\n"))
      ro.update!(plan: Plan.free)
      ro.update_columns(disk_lost_at: 2.days.ago)

      # ── Org E: full (pool 1 GB, all used) and Org F: 85 percent ────────────
      full, full_owner = org_for.("e2e-full", "Full House", Plan.max, "e2e_full", "Felix Full")
      Disk::Node.c_root_for(full_owner)
      full.update_columns(disk_quota_override_gb: 1, disk_bytes_used: 1.gigabyte)
      warn, warn_owner = org_for.("e2e-warn", "Nearly Full", Plan.max, "e2e_warn", "Wanda Warn")
      Disk::Node.c_root_for(warn_owner)
      warn.update_columns(disk_quota_override_gb: 1, disk_bytes_used: (0.85 * 1.gigabyte).to_i)

      # Imports (F10) in each state, as the importer would leave them: the adapters'
      # provider URLs are fixed, so no import can run here against a fake provider.
      # No connection rows: listing a connected source would call the real provider.
      imp = lambda do |provider, kind, name, state, **attrs|
        Disk::Import.create!(organization: org, membership: owner, provider: provider, space_kind: kind, space_name: name,
                             state: state, target_node: oc, started_at: 5.minutes.ago, **attrs)
      end
      running = imp.("google", "personal", "My Drive", "running", counts: { files: 12, folders: 3, bytes: 48_000 })
      paused = imp.("dropbox", "personal", "Dropbox", "paused", pause_reason: "quota", counts: { files: 3, folders: 1, bytes: 9000 })
      done = imp.("microsoft", "shared", "Sales library", "done", finished_at: 1.minute.ago,
                  counts: { files: 40, folders: 6, bytes: 2_000_000, skipped: 1, failed: 1 },
                  report: { "unmatched_people" => { "outside@partner.e2e.test" => 2 } })
      queued = imp.("google", "personal", "Old Drive", "queued", counts: {})
      item = lambda do |source_id, name, status, reason = nil, detail = {}|
        Disk::ImportItem.create!(organization: org, import: done, provider: "microsoft", source_id: source_id, name: name,
                                 status: status, reason: reason, detail: detail, target_node_id: oc.id)
      end
      item.("s1", "Team notebook", "skipped", "OneNote notebooks have no file content")
      item.("s2", "bad-hash.pdf", "failed", "the download did not match the source's hash after a retry")
      item.("s3", "Plan.docx", "done", nil, { "renamed_from" => "plan.docx", "rename_reason" => "names differ only in case",
                                               "clashed_with" => "plan.docx" })
      item.("s4", "Roadmap", "done", nil, { "converted" => true, "format" => "page", "hash_verified" => false })
      item.("s5", "Price list.xlsx", "done", nil, { "public_link" => true })
      out[:imports] = { running: running.key, paused: paused.key, done: done.key, queued: queued.key }

      # ── Org H: importers (F10), run for real against fake-providers.mjs ──
      # Cal is matched by the email he signs in with; Stan, at the source too, is no member.
      imp_org, ivy = org_for.("e2e-imp", "Import Works", Plan.max, "e2e_ivy", "Ivy Importer")
      cal = user.("e2e_cal", "Cal Colleague", imp_org, Membership::ROLE_MEMBER)
      { ivy => "ivy", cal => "cal" }.each do |m, name|
        OauthIdentity.create!(user: m.user, provider: "google", uid: "e2e-#{name}", email: "#{name}@imp.e2e.test")
        Disk::Node.c_root_for(m)
      end

      # ── Org G: sealing (F7). Nothing sealed is made here: identity keys and
      # every sealed item come from the real browser client (global-setup.js
      # and the specs), so the suite exercises the real crypto against the API.
      _seal, = org_for.("e2e-seal", "Sealed Works", Plan.max, "e2e_sol", "Sol Sealer")
      seal = Organization.find_by!(slug: "e2e-seal")
      user.("e2e_sam", "Sam Holder", seal, Membership::ROLE_MEMBER)
      user.("e2e_sue", "Sue Leaver", seal, Membership::ROLE_MEMBER)
      user.("e2e_sid", "Sid Admin", seal, Membership::ROLE_ADMIN)
      user.("e2e_lou", "Lou Leaving", seal, Membership::ROLE_MEMBER) # disabled mid-test: the leaver freeze
      user.("e2e_lia", "Lia Leaving", seal, Membership::ROLE_MEMBER) # the same, for the phone screenshots
      user.("e2e_lex", "Lex Leaving", seal, Membership::ROLE_MEMBER) # disabled mid-test: links refused while frozen
      user.("e2e_tom", "Tom Nokey", seal, Membership::ROLE_MEMBER) # never gets an identity key
      out[:sealed_people] = %w[e2e_sol e2e_sam e2e_sue e2e_sid e2e_lou e2e_lia e2e_lex]

      File.write(out_path, JSON.pretty_generate(out))
      puts "e2e:disk:seed wrote #{out_path}: #{out[:users].size} people, #{out[:nodes].size} items, #{out[:links].size} links"
    end
  end
end
