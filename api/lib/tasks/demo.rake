# Demo environment for screen recordings.
#
#   bin/rails demo:brightfold    build/refresh the Brightfold MX workspace
#   bin/rails demo:purge_e2e     drop leftover e2e-console-*.test domains
#   bin/rails demo:reset         purge_e2e + rebuild Brightfold from scratch
#
# Brightfold is the same fictional creative studio the DESKTOP demo seed uses
# (ui/desktop/scripts/seed_demo.py) — same team, same clients, same vendors. The
# split is deliberate and is the story the videos tell:
#
#   brightfold.com  — the inbox2-HOSTED domain (this task). Team mail, MX.
#   brightfold.co   — their legacy Gmail/Outlook + social channels, connected as
#                     local channels by seed_demo.py.
#
# So one company shows up across both halves of the product without the same
# address appearing twice. Everything here is idempotent: re-running refreshes
# content in place rather than duplicating it.
#
# Never runs against production — Brightfold is demo data and the guard below
# mirrors db/seeds.rb.

require "base64"

namespace :demo do
  BRIGHTFOLD_SLUG = "brightfold".freeze
  BRIGHTFOLD_DOMAIN = "brightfold.com".freeze

  # ── Team ───────────────────────────────────────────────────────────────────
  # username, display name, role, job title, personal mailbox local-part.
  TEAM = [
    ["sam",   "Sam Brightfold", :owner,  "Founder",        "sam"],
    ["aria",  "Aria Nakamura",  :admin,  "Design Director", "aria"],
    ["noor",  "Noor El-Amin",   :member, "Studio Manager",  "noor"],
    ["jonas", "Jonas Berg",     :member, "Motion Lead",     "jonas"],
    ["mina",  "Mina Okafor",    :member, "Producer",        "mina"],
    ["rafa",  "Rafael Costa",   :member, "Developer",       "rafa"]
  ].freeze

  # Shared mailboxes — owned by a member for billing/attribution, but the address
  # the outside world writes to. These are what the routing rules key on.
  SHARED_MAILBOXES = [
    ["hello",        "noor"],
    ["new-business", "sam"],
    ["billing",      "mina"],
    ["support",      "rafa"],
    ["press",        "aria"]
  ].freeze

  # ── External roster ────────────────────────────────────────────────────────
  # Mirrors seed_demo.py's contact table so the same people appear on both the
  # MX and local-channel sides of a demo. Each sends >= 2 threads so they become
  # real nodes (with edges) in the Explorer graph rather than dangling leaves.
  CONTACTS = {
    # clients
    "priya"      => ["Priya Raman",      "priya@aurorahealth.com"],
    "marcus"     => ["Marcus Webb",      "marcus@finchley.io"],
    "devon"      => ["Devon Park",       "devon@lumen.app"],
    "elena"      => ["Elena Cruz",       "elena@northwind.co"],
    "raj"        => ["Raj Malhotra",     "raj@vergemobility.com"],
    "nadia"      => ["Nadia Haddad",     "nadia@bloomwell.health"],
    "tom"        => ["Tom Fischer",      "tom@kessler-coffee.de"],
    "yuki"       => ["Yuki Tanaka",      "yuki@hanami.studio"],
    # vendors / suppliers
    "northpoint" => ["North Point Print", "billing@northpoint-print.com"],
    "tomas"      => ["Tomás Rivera",     "tomas@studiolight.com"],
    "claire"     => ["Claire Dubois",    "claire@paperhouse.fr"],
    "ben"        => ["Ben Carter",       "ben@framewright.com"],
    # partners / press / community
    "lena"       => ["Lena Ortiz",       "lena@designopssummit.com"],
    "owen"       => ["Owen Blake",       "owen@awwwards.com"],
    "mara"       => ["Mara Sinclair",    "mara@type-collective.org"],
    "ivan"       => ["Ivan Petrov",      "ivan@figma.com"],
    # prospects / inbound leads
    "coffeelab"  => ["The Coffee Lab",   "hello@thecoffeelab.co"],
    "harper"     => ["Harper Quinn",     "harper@quinnbakery.com"],
    "leo"        => ["Leo Martins",      "leo@martins-wine.pt"]
  }.freeze

  TAGS = [
    ["Client",   "#8090a8"],
    ["New biz",  "#d4a843"],
    ["Vendor",   "#c8a898"],
    ["Press",    "#b8a0b8"],
    ["Finance",  "#90a8c0"],
    ["Urgent",   "#c0a0a0"],
    ["Studio",   "#a8c098"]
  ].freeze

  # ── Threads ────────────────────────────────────────────────────────────────
  # [contact, mailbox, space, subject, tags, assignee, opts]
  #   opts: :read, :hours/:days ago, :status, :replies (array of body strings
  #         sent BY the studio), :body (the inbound opener).
  # Ordered newest-first purely for readability; ages are explicit.
  THREADS = [
    ["priya", "hello", "support", "Aurora rebrand — final logo lockups approved",
     %w[Client Urgent], "aria", {
       hours: 2, read: false,
       body: "Sam, Aria — the board signed off on the primary mark this morning. Unanimous, which almost never happens here.\n\nCan you get us the favicon and app-icon variants this week? Marketing wants to stage the new site on Thursday and the old mark is still baked into the header.\n\nAlso: the guidelines doc — is that still on for next Thursday's kickoff?",
       replies: ["Priya — brilliant news, congratulations. Favicon + app-icon variants are exporting now, you'll have them before end of day.\n\nGuidelines kickoff is still Thursday 10:00. Aria's leading it; I'll send the agenda tomorrow.\n\nSam"]
     }],

    ["raj", "new-business", "sales", "Launch pulled to Monday — can you turn the keynote deck?",
     %w[Client Urgent], "sam", {
       hours: 6, read: false,
       body: "Bad news: comms moved the launch to Monday. I know this is not what we agreed.\n\nIs there any chance you can turn the keynote deck by Friday EOD? 24 slides, mostly existing content restyled — the only genuinely new section is the pricing story.\n\nHappy to pay the rush rate. Tell me what's possible."
     }],

    ["nadia", "hello", "support", "URGENT: typo on page 3 of the brochure",
     %w[Client Urgent], "noor", {
       hours: 4, read: false,
       body: "We caught a typo on page 3 of the printed brochure — 'recieve' instead of 'receive', in the pull quote.\n\nNorth Point are holding the run until 18:00 but not a minute past. Can you re-export and send them the corrected PDF directly?",
       replies: ["Fixed and sent straight to North Point's prepress address — they've confirmed receipt and the run is going ahead tonight.\n\nI've also grepped the rest of the copy for the same mistake; page 3 was the only one.\n\nNoor"]
     }],

    ["marcus", "new-business", "sales", "Q3 retainer — room for a second motion designer?",
     %w[Client], "sam", {
       hours: 9, read: false,
       body: "We have three launches stacking up in Q3 and one motion designer between them is going to hurt.\n\nCan we expand the retainer to cover a second? I'd rather commit now than scramble in August. Send me a revised scope and I'll get it through procurement."
     }],

    ["devon", "hello", "support", "Lumen design system — component audit findings",
     %w[Client Studio], "rafa", {
       hours: 14, read: true,
       body: "Ran the audit across the app. 34 components in Figma, 19 actually implemented, and 6 of those have drifted far enough that they're effectively bespoke.\n\nThe worst offenders are the form controls. Attaching the spreadsheet — the 'drift' column is the one to look at.\n\nWhat's the sensible order of attack here?",
       replies: ["Devon — the form controls are the right place to start; they're also the ones users touch most.\n\nMy suggestion: fix the tokens first (spacing + focus ring are inconsistent across all six), then re-derive the components from those rather than patching each in isolation. Otherwise we'll be back here in a quarter.\n\nI can scope that as a two-week piece if useful.\n\nRafa"]
     }],

    ["elena", "hello", "support", "Northwind packaging — dieline revisions",
     %w[Client], "aria", {
       hours: 20, read: true,
       body: "Attached the revised dielines from the structural engineer. Two changes: the tuck flap is 3mm deeper and the window moved 8mm toward the spine.\n\nDoes that break the artwork? The window shift worries me — the illustration was quite tightly cropped."
     }],

    ["owen", "press", "marketing", "Awwwards — Site of the Day nomination",
     %w[Press], "aria", {
       days: 1, hours: 2, read: false,
       body: "Hi Brightfold — the Lumen site has been nominated for Site of the Day.\n\nWe need a short studio blurb (max 60 words), a hero image at 1600x1200, and the credits list by Friday. Judging opens Monday.\n\nCongratulations, it's a strong entry."
     }],

    ["lena", "press", "marketing", "DesignOps Summit — speaker slot confirmed",
     %w[Press], "aria", {
       days: 1, hours: 5, read: true,
       body: "Delighted to confirm Aria for the 40-minute slot on the Thursday afternoon track.\n\nWe'll need the talk title and abstract by the 15th for the printed programme, plus a headshot at 2000px. Travel and two nights' accommodation are covered.",
       replies: ["Lena — confirmed, thank you. Working title: 'The design system nobody maintains'. Abstract and headshot will be with you well before the 15th.\n\nAria"]
     }],

    ["northpoint", "billing", "finance", "Invoice NP-4471 — 30 days overdue",
     %w[Vendor Finance], "mina", {
       days: 1, hours: 8, read: false,
       body: "Our records show invoice NP-4471 (£4,280, the Aurora brochure run) is now 30 days past due.\n\nCould you confirm when we can expect payment? If it's already been sent, apologies — please send the remittance advice and we'll trace it."
     }],

    ["tom", "hello", "support", "Kessler Coffee — packaging photography brief",
     %w[Client], "mina", {
       days: 2, read: true,
       body: "Guten Tag Brightfold,\n\nWe need product photography for the new single-origin range — six SKUs, both on white and in an atmospheric set. The bags land with us on the 12th.\n\nCan you handle the shoot or should we source a photographer? Either is fine; we'd rather you art-direct in both cases.",
       replies: ["Tom — we can handle both. Tomás at Studio Light shoots most of our packaging work and he's excellent with reflective surfaces, which matters for the foil bags.\n\nI'll get a quote over this week. Assume two days: one for the white, one for the set.\n\nMina"]
     }],

    ["yuki", "new-business", "sales", "Hanami x Brightfold — collaboration?",
     ["New biz"], nil, {
       days: 2, hours: 4, read: false,
       body: "Hello from Tokyo,\n\nWe've admired the Aurora work for a while. We're a six-person studio doing mostly editorial and type design, and we're increasingly asked for brand work we don't want to turn down.\n\nWould you be open to a conversation about partnering on larger pitches? No agenda beyond that."
     }],

    ["ivan", "hello", "support", "Figma — org plan migration on the 30th",
     %w[Vendor], "rafa", {
       days: 2, hours: 9, read: true,
       body: "Heads up that your team is scheduled to migrate to the Organization plan on the 30th.\n\nNothing should break, but shared libraries move under a new namespace — if you have plugins pointing at library IDs directly, those will need updating.\n\nLet me know if you'd like me to walk someone through it beforehand."
     }],

    ["claire", "billing", "finance", "Paperhouse — Q3 stock quote",
     %w[Vendor Finance], "mina", {
       days: 3, read: true,
       body: "Bonjour,\n\nQuote attached for the Q3 paper stock. Prices are up 6% on last quarter — pulp costs, unfortunately, not us.\n\nThe Colorplan is the same; it's the uncoated ranges that moved. If you commit to the full quarter now I can hold Q2 pricing."
     }],

    ["coffeelab", "new-business", "sales", "Enquiry — full brand identity",
     ["New biz"], "sam", {
       days: 3, hours: 3, read: false,
       body: "Hi,\n\nWe're a small specialty coffee roaster opening our second site next spring, and the brand we launched with no longer fits.\n\nWe'd need identity, packaging and signage. Budget is real but not enormous. Is that the kind of project you'd take on?"
     }],

    ["harper", "new-business", "sales", "Quinn Bakery — packaging refresh",
     ["New biz"], nil, {
       days: 4, read: true,
       body: "Hello! Found you through the Kessler Coffee work, which is gorgeous.\n\nWe make sourdough and pastries for about 40 cafes around the city and our packaging is embarrassing. Would love to talk. What does a project like that usually run to?"
     }],

    ["ben", "hello", "support", "Framewright — Aurora signage install date",
     %w[Vendor], "noor", {
       days: 4, hours: 6, read: true,
       body: "We can get the Aurora reception signage installed on either the 18th or the 22nd. The 18th is a Saturday so there's no disruption to their floor.\n\nNeed the final artwork three working days before whichever you pick.",
       replies: ["The 18th works — please book it. Final artwork is with you by Tuesday at the latest.\n\nNoor"]
     }],

    ["mara", "press", "marketing", "Type Collective — Aurora typeface licensing",
     %w[Press Vendor], "aria", {
       days: 5, read: true,
       body: "Following up on the Aurora custom cut. Legal have asked me to pin down the licensing terms before we go further.\n\nThe studio retains the drawing rights; Aurora get exclusive commercial use in health and adjacent categories for five years. Does that match your understanding?"
     }],

    ["tomas", "billing", "finance", "Studio Light — shoot quote, Kessler range",
     %w[Vendor Finance], "mina", {
       days: 5, hours: 4, read: false,
       body: "Hola Mina,\n\nTwo days as discussed. Day one white background, six SKUs, full retouch. Day two set build and atmospheric.\n\nQuote attached. The set build is the variable — if Kessler want the wooden counter I priced, add a half day for construction."
     }],

    ["priya", "billing", "finance", "PO 88301 raised — Aurora phase 2",
     %w[Client Finance], "mina", {
       days: 6, read: true,
       body: "PO 88301 is raised and approved for phase 2. Please invoice against it rather than the old number, procurement are strict about this.\n\nNet 30 from invoice date as before."
     }],

    ["devon", "support", "support", "Lumen — token export is producing invalid CSS",
     %w[Client Studio], "rafa", {
       days: 6, hours: 5, read: true,
       body: "The token export is emitting `--space-: 4px` for a few entries — empty name segment, so the variable is unusable.\n\nLooks like it's the tokens with a numeric-only leaf. Not urgent but it's breaking our build lint.",
       replies: ["Confirmed — the naming function drops purely numeric segments. Fixed on our side and I've pushed a new export.\n\nWorth pinning the exporter version in your build so this can't surprise you again; I've put the version in the README.\n\nRafa"]
     }],

    ["raj", "hello", "support", "Verge Mobility — motion guidelines draft",
     %w[Client Studio], "jonas", {
       days: 7, read: true,
       body: "Read the motion guidelines draft on the train. Really good — the easing section especially.\n\nOne gap: nothing about reduced-motion. Our accessibility audit flagged it last year and I'd rather not get flagged again.",
       replies: ["Good catch, and an obvious omission on my part.\n\nAdding a section covering prefers-reduced-motion: which animations become instant, which keep a shortened form, and which are decorative enough to drop entirely. Draft back to you Thursday.\n\nJonas"]
     }],

    ["elena", "billing", "finance", "Northwind — remittance for INV-2291",
     %w[Client Finance], "mina", {
       days: 7, hours: 3, read: true,
       body: "Remittance attached — INV-2291 paid in full today, should clear with you within two working days.\n\nSorry it ran late, our finance system migration ate a fortnight."
     }],

    ["nadia", "hello", "support", "Bloomwell — brand guidelines feedback",
     %w[Client], "aria", {
       days: 8, read: true,
       body: "Team have been through the guidelines. Broadly delighted.\n\nTwo notes: the photography section feels thin next to everything else, and we'd like a page on tone of voice for clinical contexts — our writers keep asking and we keep improvising."
     }],

    ["marcus", "hello", "support", "Finchley — Q2 retrospective notes",
     %w[Client], "sam", {
       days: 9, read: true,
       body: "Notes from our internal retro, shared in the spirit of us both getting better at this.\n\nWhat worked: the weekly Thursday call, the shared Figma, Jonas generally.\nWhat didn't: two rounds of feedback arriving after sign-off, which was our fault, and the handover doc being late, which was yours.\n\nHappy with where we landed overall.",
       replies: ["Marcus — appreciated, and fair on both counts.\n\nThe handover doc being late is on me; we've since made it a gate on the project template rather than something someone remembers to do. The post-sign-off feedback we can absorb if it comes with a date.\n\nSee you Thursday.\n\nSam"]
     }],

    ["tom", "billing", "finance", "Kessler — invoice query, VAT treatment",
     %w[Client Finance], "mina", {
       days: 10, read: true,
       body: "Our accountant is querying the VAT on your last invoice — as a German business we should be reverse-charged, but VAT has been added.\n\nCould you check and reissue if needed? Our VAT number is on the PO."
     }],

    ["owen", "press", "marketing", "Awwwards — jury feedback, Aurora site",
     %w[Press], nil, {
       days: 11, read: true,
       body: "Jury scores are in for the Aurora site: 7.8 design, 8.4 usability, 7.1 creativity, 8.0 content. Solid across the board.\n\nThe creativity score is the one holding it back — a couple of jurors felt the layout system was safe. Not a criticism I'd lose sleep over."
     }],

    ["yuki", "hello", "support", "Hanami — happy to sign the mutual NDA",
     ["New biz"], "sam", {
       days: 12, read: true,
       body: "Signed copy attached.\n\nOn the partnering conversation — we have a healthcare pitch in October that would suit this well. Shall we use it as the test case?"
     }],

    ["leo", "new-business", "sales", "Martins Wine — label design for two ranges",
     ["New biz"], nil, {
       days: 13, read: true,
       body: "Boa tarde,\n\nWe are a family winery in the Douro, third generation. Two ranges need new labels — the entry range and a reserve.\n\nWe have seen the Kessler Coffee work. Would you be interested? We can travel."
     }],

    ["ivan", "support", "support", "Figma — shared library permissions question",
     %w[Vendor], "rafa", {
       days: 14, read: true,
       body: "You asked about restricting who can publish to a shared library.\n\nShort version: it's controlled at the file level, not the library level, so you want the source file in a project only the design leads can edit. Everyone else consumes it."
     }],

    ["priya", "hello", "support", "Aurora — phase 2 kickoff agenda",
     %w[Client], "sam", {
       days: 15, read: true,
       body: "Agenda for Thursday, tell me what's missing:\n\n1. Phase 1 recap and what we learned\n2. Scope for phase 2 — product UI, not just brand\n3. Team and availability through to December\n4. The website question (do we rebuild or restyle?)\n5. Budget\n\nNinety minutes should do it."
     }],

    ["claire", "hello", "support", "Paperhouse — swatch book on its way",
     %w[Vendor], "noor", {
       days: 16, read: true,
       body: "Sent the new swatch book this morning, should reach you Thursday.\n\nThe two new uncoated whites are at the back — worth a look for the Aurora stationery, they take foil far better than the current stock."
     }],

    ["devon", "hello", "support", "Lumen — thank you",
     %w[Client], nil, {
       days: 18, read: true,
       body: "Just wanted to say: we shipped the redesign on Tuesday and support tickets about 'where has X gone' are running at about a fifth of what we braced for.\n\nWhatever you did with the navigation, it worked. Thank you."
     }],

    ["ben", "billing", "finance", "Framewright — final invoice, Aurora signage",
     %w[Vendor Finance], "mina", {
       days: 19, read: true,
       body: "Final invoice attached for the Aurora reception signage — install went smoothly on the 18th, no snags.\n\nPhotos attached too, in case they're useful for your portfolio."
     }],

    ["mara", "hello", "support", "Type Collective — talk at the next meetup?",
     %w[Press], "aria", {
       days: 21, read: true,
       body: "Would one of you be up for a 20-minute talk at the next meetup? Roughly 60 people, informal, in the usual room above the pub.\n\nThe custom typeface process would go down very well with this crowd."
     }],

    ["nadia", "support", "support", "Bloomwell — asset portal login not working",
     %w[Client], "rafa", {
       days: 22, read: true,
       body: "Three of our team can't get into the asset portal — it accepts the password then bounces straight back to the login screen.\n\nWorks fine for me, which is unhelpful. All three are on Safari if that's relevant.",
       replies: ["It's relevant — Safari's cookie policy is rejecting the session cookie because it was set on a subdomain. Fixed the cookie domain and all three should be able to log in now.\n\nSorry about that, it's an embarrassing one.\n\nRafa"]
     }]
  ].freeze

  # ── Background volume ──────────────────────────────────────────────────────
  # The 35 threads above are the ones worth opening on camera. Real inboxes are
  # mostly NOT that — they're receipts, digests, delivery notices and status
  # pings. Without a layer of those the list runs dry after two screens and the
  # inbox reads as staged. Each entry is a template expanded once per occurrence
  # over the trailing 9 weeks; `%s` takes the occurrence number.
  #   [sender name, sender email, mailbox, space, subject, body, tags, count]
  ROUTINE = [
    ["North Point Print", "dispatch@northpoint-print.com", "billing", "finance",
     "Order NP-44%s dispatched",
     "Your order has left our facility and is with the courier.\n\nTracking is available from the portal. Delivery is normally next working day for mainland addresses.",
     %w[Vendor], 7],

    ["Figma", "digest@figma.com", "hello", "triage",
     "Weekly digest — %s comments across your files",
     "Here's what happened in your team files this week.\n\nMost active file: Aurora — Brand. Most commented frame: Logo lockups / primary.\n\nOpen Figma to catch up.",
     %w[Vendor], 8],

    ["Adobe", "receipts@adobe.com", "billing", "finance",
     "Receipt for Creative Cloud — seat %s",
     "Thanks for your payment. Your Creative Cloud for teams subscription has renewed for another month.\n\nThis receipt is also available in your account under Billing history.",
     %w[Vendor Finance], 6],

    ["Dropbox", "no-reply@dropbox.com", "hello", "triage",
     "Aurora — Delivery %s shared with you",
     "A folder has been shared with your team.\n\nIt will stay available for 30 days, after which the link expires. Download anything you need to keep.",
     %w[Vendor], 6],

    ["Studio Light", "bookings@studiolight.com", "billing", "finance",
     "Studio hire confirmation — booking %s",
     "Your studio booking is confirmed.\n\nLoad-in is from 08:00, and the space must be cleared by 19:00. Parking for one van is included; let us know if you need a second bay.",
     %w[Vendor], 5],

    ["Paperhouse", "orders@paperhouse.fr", "billing", "finance",
     "Commande %s — confirmation d'expédition",
     "Votre commande a été expédiée aujourd'hui.\n\nLivraison estimée sous 3 à 5 jours ouvrés. La facture suit par email séparé.",
     %w[Vendor], 4],

    ["Awwwards", "hello@awwwards.com", "press", "marketing",
     "This week's winners — issue %s",
     "The Sites of the Day from the past week, plus a look at the honourable mentions.\n\nSubmissions for next month's Site of the Month close on Friday.",
     %w[Press], 6],

    ["DesignOps Summit", "updates@designopssummit.com", "press", "marketing",
     "Programme update %s — new sessions announced",
     "Six new sessions have been added to the programme, including two workshops on design system governance.\n\nSpeaker travel details go out separately next week.",
     %w[Press], 4],

    ["Lumen", "notifications@lumen.app", "support", "support",
     "Deploy %s completed — design system package",
     "The design system package has been deployed to production.\n\nNo failing checks. Bundle size changed by less than 1%.",
     %w[Client Studio], 7],

    ["Aurora Health", "no-reply@aurorahealth.com", "hello", "support",
     "Asset portal — %s new files added",
     "New files have been added to the shared asset portal by the Aurora marketing team.\n\nYou are receiving this because you are a collaborator on the Aurora brand workspace.",
     %w[Client], 5]
  ].freeze

  # ── HTML newsletters ───────────────────────────────────────────────────────
  # Everything above is prose mail, which is not what an inbox actually looks
  # like — a real one is half marketing HTML, and that's also the half that
  # exercises the reader (table layouts, dark templates, full-bleed backgrounds,
  # non-Latin copy, image grids). These are hand-authored so a video can open one
  # and it looks like mail from a real company.
  #
  # Every image is an inline SVG data-URI. The reader's iframe runs
  # `img-src data: blob:` and blocks remote images until the reader consents, so
  # a newsletter built on remote <img> tags renders as a column of broken frames
  # on camera — and needs the network to render at all. data: images are always
  # allowed, need nothing, and can't phone home.

  # Deterministic abstract artwork — a gradient plus a few shapes placed from the
  # seed. Stands in for the photography a real newsletter would use.
  def nl_art(w, h, c1, c2, seed = 0)
    shapes = (0..2).map do |i|
      cx = (seed * 37 + i * 149) % w
      cy = (seed * 23 + i * 71) % h
      r  = (h / 3.0 * (1.0 + ((seed + i) % 3) * 0.35)).round
      op = [0.20, 0.13, 0.28][i]
      %(<circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="#fff" opacity="#{op}"/>)
    end.join
    bar = %(<rect x="#{(seed * 53) % w}" y="0" width="#{(h / 4.0).round}" height="#{h}" ) +
          %(fill="#000" opacity="0.10" transform="rotate(12 #{w / 2} #{h / 2})"/>)
    nl_svg(
      %(<svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}" viewBox="0 0 #{w} #{h}">) +
      %(<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">) +
      %(<stop offset="0" stop-color="#{c1}"/><stop offset="1" stop-color="#{c2}"/>) +
      %(</linearGradient></defs><rect width="#{w}" height="#{h}" fill="url(#g)"/>) +
      shapes + bar + "</svg>"
    )
  end

  # A round monogram — brand logo in a header, or a speaker's face in a lineup.
  def nl_avatar(letters, bg, fg = "#ffffff", size = 96)
    nl_svg(
      %(<svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}" viewBox="0 0 96 96">) +
      %(<circle cx="48" cy="48" r="48" fill="#{bg}"/>) +
      %(<text x="48" y="48" dy="0.35em" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" ) +
      %(font-size="#{letters.length > 1 ? 34 : 44}" font-weight="700" fill="#{fg}">#{letters}</text></svg>)
    )
  end

  # base64, not percent-encoding: an SVG carries `#`, `"` and `<` on nearly every
  # line, and one missed escape is an image that silently fails to decode.
  def nl_svg(svg) = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"

  # A genuinely remote image, on purpose. Most artwork here is a data-URI so the
  # demo renders with no network — but a demo where nothing is remote can never
  # show the reader blocking images and the "Show images" banner, which is one of
  # its better features. Three newsletters carry a remote hero so that banner has
  # something to be about; the rest stay fully offline, and each of the three is
  # laid out so it still reads as a finished email with the hero missing.
  #
  # width+height are explicit because a blocked image is emptied in place: without
  # them the card jumps by the hero's height the moment the reader consents.
  # picsum.photos is a stable id-addressed host — /id/431/ is always the same photo.
  def nl_remote(id, w, h, alt = "")
    %(<img src="https://picsum.photos/id/#{id}/#{w}/#{h}" width="#{w}" height="#{h}" ) +
      %(alt="#{alt}" style="display:block;width:100%;height:auto;background:#e6e8ec;">)
  end

  # Bulletproof (table-based) CTA button — the shape every real template uses,
  # because a styled <a> collapses in Outlook.
  def nl_button(label, bg, fg = "#ffffff", radius = 8)
    %(<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>) +
      %(<td align="center" bgcolor="#{bg}" style="border-radius:#{radius}px;">) +
      %(<a href="https://example.com/" style="display:inline-block;padding:13px 26px;font-size:15px;) +
      %(font-weight:600;color:#{fg};text-decoration:none;border-radius:#{radius}px;">#{label}</a>) +
      %(</td></tr></table>)
  end

  def nl_cell(inner, pad = "26px 32px", bg = nil)
    %(<tr><td style="padding:#{pad};#{bg ? "background:#{bg};" : ''}">#{inner}</td></tr>)
  end

  # The outer scaffold: page background, hidden preheader, centred 600px card.
  # The preheader div is the grey line a real client shows after the subject —
  # invisible in the body, which is exactly what senders do with it.
  def nl_wrap(preheader, rows, page = "#eef1f6", card = "#ffffff")
    %(<div style="background:#{page};padding:28px 12px;font-family:-apple-system,BlinkMacSystemFont,) +
      %('Segoe UI',Helvetica,Arial,sans-serif;">) +
      %(<div style="display:none;max-height:0;overflow:hidden;opacity:0;">#{preheader}</div>) +
      %(<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" align="center" ) +
      %(style="width:600px;max-width:100%;margin:0 auto;background:#{card};border-radius:14px;overflow:hidden;">) +
      rows + %(</table></div>)
  end

  def nl_footer(lines, bg = "#f6f7f9", fg = "#8a93a5")
    nl_cell(
      %(<p style="margin:0 0 8px;font-size:12px;line-height:1.6;color:#{fg};">#{lines}</p>) +
      %(<p style="margin:0;font-size:12px;color:#{fg};">) +
      %(<a href="https://example.com/unsubscribe" style="color:#{fg};">Unsubscribe</a> &nbsp;·&nbsp; ) +
      %(<a href="https://example.com/preferences" style="color:#{fg};">Email preferences</a> &nbsp;·&nbsp; ) +
      %(<a href="https://example.com/view" style="color:#{fg};">View in browser</a></p>),
      "22px 32px", bg
    )
  end

  # [sender, from address, mailbox, space, subject, preheader (= snippet), tags,
  #  days ago, read, html]
  NEWSLETTERS = [
    # ── Product update: light, three feature blocks, one CTA ─────────────────
    ["Figma", "product@figma.com", "hello", "triage",
     "New in Figma — variables, Dev Mode inspect, and faster boolean ops",
     "Three things we shipped this month, and one we're retiring.",
     %w[Vendor], 1, false,
     nl_wrap(
       "Three things we shipped this month, and one we're retiring.",
       nl_cell(
         %(<img src="#{nl_avatar('F', '#ffffff', '#0d0d0d', 72)}" width="36" height="36" alt="Figma" ) +
         %(style="display:block;border-radius:50%;">), "22px 32px 20px", "#0d0d0d"
       ) +
       %(<tr><td style="padding:0;"><img src="#{nl_art(600, 200, '#8B5CF6', '#EC4899', 3)}" ) +
       %(width="600" alt="" style="display:block;width:100%;"></td></tr>) +
       nl_cell(
         %(<p style="margin:0 0 6px;font-size:12px;letter-spacing:.09em;text-transform:uppercase;) +
         %(color:#8B5CF6;font-weight:700;">Product update · August</p>) +
         %(<h1 style="margin:0 0 12px;font-size:26px;line-height:1.25;color:#111827;">) +
         %(Three things we shipped this month</h1>) +
         %(<p style="margin:0;font-size:15px;line-height:1.65;color:#4b5563;">) +
         %(Plus a heads-up about a legacy API we're switching off in October — worth ) +
         %(a read if your team automates exports.</p>), "30px 32px 8px"
       ) +
       [
         ["Variables everywhere", "Modes now cascade through nested components, so a single theme " \
          "switch flips an entire flow — no more duplicated frames per brand.", "#6366F1", "#22D3EE", 5],
         ["Dev Mode inspect", "Inspect now reads your codebase's own token names when a file is " \
          "linked through Code Connect, instead of raw hex values.", "#F59E0B", "#EF4444", 8],
         ["Faster boolean ops", "Union and subtract on complex vector networks are roughly four " \
          "times quicker, which mostly shows up in icon work.", "#10B981", "#3B82F6", 11]
       ].map { |title, text, c1, c2, seed|
         nl_cell(
           %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>) +
           %(<td width="132" valign="top" style="padding-right:18px;">) +
           %(<img src="#{nl_art(132, 96, c1, c2, seed)}" width="132" height="96" alt="" ) +
           %(style="display:block;border-radius:8px;"></td>) +
           %(<td valign="top">) +
           %(<h2 style="margin:0 0 6px;font-size:17px;color:#111827;">#{title}</h2>) +
           %(<p style="margin:0;font-size:14px;line-height:1.6;color:#4b5563;">#{text}</p>) +
           %(</td></tr></table>), "16px 32px"
         )
       }.join +
       nl_cell(nl_button("See what's new", "#0d0d0d"), "12px 32px 30px") +
       nl_footer("Figma, 760 Market St, San Francisco, CA. You're getting this because " \
                 "you have a Figma account.")
     )],

    # ── Gallery: dark template, image cards, score badges ────────────────────
    ["Awwwards", "hello@awwwards.com", "press", "marketing",
     "Sites of the Day · Week 33",
     "Five winners this week, including a portfolio built entirely in WebGL.",
     %w[Press], 3, false,
     nl_wrap(
       "Five winners this week, including a portfolio built entirely in WebGL.",
       nl_cell(
         %(<h1 style="margin:0;font-size:15px;letter-spacing:.32em;text-transform:uppercase;) +
         %(color:#ffffff;font-weight:600;">Awwwards</h1>), "26px 32px 0", "#111214"
       ) +
       nl_cell(
         %(<h2 style="margin:0 0 6px;font-size:28px;line-height:1.2;color:#ffffff;">) +
         %(Sites of the Day</h2>) +
         %(<p style="margin:0;font-size:14px;color:#8b8f98;">Week 33 &nbsp;·&nbsp; ) +
         %(five winners, twelve honourable mentions</p>), "20px 32px 8px", "#111214"
       ) +
       [
         ["Atlas Oceanic", "Studio Verre", "8.42", "#0EA5E9", "#1E3A8A", 2],
         ["Maison Ferrant", "Bureau Nord", "8.19", "#F97316", "#7C2D12", 6],
         ["Halcyon Type Foundry", "Independent", "8.07", "#A855F7", "#312E81", 9]
       ].map { |site, studio, score, c1, c2, seed|
         nl_cell(
           %(<img src="#{nl_art(536, 240, c1, c2, seed)}" width="536" alt="#{site}" ) +
           %(style="display:block;width:100%;border-radius:10px;">) +
           %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ) +
           %(style="margin-top:12px;"><tr><td valign="middle">) +
           %(<p style="margin:0;font-size:17px;color:#ffffff;font-weight:600;">#{site}</p>) +
           %(<p style="margin:2px 0 0;font-size:13px;color:#8b8f98;">#{studio}</p></td>) +
           %(<td align="right" valign="middle"><span style="display:inline-block;padding:6px 12px;) +
           %(border:1px solid #2c2e34;border-radius:20px;font-size:13px;font-weight:700;) +
           %(color:#ffd66b;">#{score}</span></td></tr></table>), "16px 32px", "#111214"
         )
       }.join +
       nl_cell(nl_button("View all winners", "#ffd66b", "#111214", 24) +
               %(<p style="margin:16px 0 0;font-size:13px;color:#8b8f98;">) +
               %(Submissions for Site of the Month close Friday at 18:00 CET.</p>),
               "14px 32px 30px", "#111214") +
       nl_footer("Awwwards SL, Carrer de Pallars 108, Barcelona. Sent weekly to jury members " \
                 "and subscribers.", "#0a0b0d", "#6b7080"),
       "#000000", "#111214"
     )],

    # ── E-commerce, and not in English ───────────────────────────────────────
    ["Kessler Coffee", "newsletter@kessler-coffee.de", "hello", "triage",
     "Neue Ernte: Kolumbien Huila ist da",
     "Frisch geröstet, ab heute im Shop — und 15% auf das Probierpaket.",
     %w[Client], 5, true,
     nl_wrap(
       "Frisch geröstet, ab heute im Shop — und 15% auf das Probierpaket.",
       %(<tr><td style="padding:0;">#{nl_remote(431, 600, 250, 'Kolumbien Huila')}</td></tr>) +
       nl_cell(
         %(<p style="margin:0 0 8px;font-size:12px;letter-spacing:.14em;text-transform:uppercase;) +
         %(color:#B45309;font-weight:700;">Ernte 2026</p>) +
         %(<h1 style="margin:0 0 12px;font-size:27px;line-height:1.25;color:#231a14;">) +
         %(Kolumbien Huila — jetzt im Shop</h1>) +
         %(<p style="margin:0;font-size:15px;line-height:1.7;color:#5b4a3f;">) +
         %(Karamell, Orangenzeste und ein langer, weicher Abgang. Wir haben nur ) +
         %(340&nbsp;kg bekommen — erfahrungsgemäß ist das in zwei Wochen weg.</p>),
         "30px 32px 10px"
       ) +
       nl_cell(
         %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>) +
         [
           ["Huila", "250 g · ganze Bohne", "14,50 €", "#D97706", "#92400E", 1],
           ["Probierpaket", "3 × 100 g", "18,90 €", "#78350F", "#B45309", 7],
           ["Espresso Nr. 4", "1 kg · Abo", "39,00 €", "#57534E", "#292524", 12]
         ].map { |name, meta, price, c1, c2, seed|
           %(<td width="168" valign="top" style="padding-right:12px;">) +
           %(<img src="#{nl_art(168, 132, c1, c2, seed)}" width="168" height="132" alt="#{name}" ) +
           %(style="display:block;width:100%;border-radius:8px;">) +
           %(<p style="margin:10px 0 2px;font-size:15px;font-weight:600;color:#231a14;">#{name}</p>) +
           %(<p style="margin:0 0 4px;font-size:12px;color:#8a7a6d;">#{meta}</p>) +
           %(<p style="margin:0;font-size:15px;font-weight:700;color:#B45309;">#{price}</p></td>)
         }.join + %(</tr></table>), "10px 32px 18px"
       ) +
       nl_cell(
         %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ) +
         %(style="border:1px dashed #d6c3b0;border-radius:10px;background:#fdf8f2;"><tr>) +
         %(<td align="center" style="padding:18px;">) +
         %(<p style="margin:0 0 4px;font-size:13px;color:#8a7a6d;">15% auf das Probierpaket ) +
         %(bis Sonntag</p>) +
         %(<p style="margin:0;font-size:22px;letter-spacing:.16em;font-weight:700;color:#231a14;">) +
         %(HUILA15</p></td></tr></table>), "0 32px 20px"
       ) +
       nl_cell(nl_button("Jetzt bestellen", "#B45309"), "0 32px 30px") +
       nl_footer("Kessler Coffee Rösterei GmbH, Bergmannstraße 12, 10961 Berlin. " \
                 "Du erhältst diese Mail, weil du unseren Newsletter abonniert hast.",
                 "#faf6f1", "#9c8b7c"),
       "#f3ece4"
     )],

    # ── Event: lineup, agenda, deadline strip ────────────────────────────────
    ["DesignOps Summit", "programme@designopssummit.com", "press", "marketing",
     "Six new sessions announced — and early bird closes Friday",
     "The full track list is live, including two governance workshops.",
     %w[Press], 8, true,
     nl_wrap(
       "The full track list is live, including two governance workshops.",
       nl_cell(
         %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>) +
         %(<td valign="middle"><p style="margin:0;font-size:14px;letter-spacing:.16em;) +
         %(text-transform:uppercase;color:#ccfbf1;font-weight:700;">DesignOps Summit</p>) +
         %(<p style="margin:4px 0 0;font-size:13px;color:#99f6e4;">Rotterdam · 14–15 October 2026</p>) +
         %(</td><td align="right" valign="middle">) +
         %(<span style="display:inline-block;padding:8px 14px;background:rgba(255,255,255,.14);) +
         %(border-radius:8px;font-size:13px;color:#ffffff;font-weight:600;">Day 1 · 09:30</span>) +
         %(</td></tr></table>), "26px 32px", "#0f766e"
       ) +
       %(<tr><td style="padding:0;">#{nl_remote(1043, 600, 200, 'Rotterdam')}</td></tr>) +
       nl_cell(
         %(<h1 style="margin:0 0 12px;font-size:26px;line-height:1.25;color:#0f172a;">) +
         %(Six new sessions, two of them workshops</h1>) +
         %(<p style="margin:0;font-size:15px;line-height:1.65;color:#475569;">) +
         %(The governance track is the one we get asked about most, so this year it's ) +
         %(hands-on: bring a real design system and leave with a written policy for it.</p>),
         "30px 32px 14px"
       ) +
       nl_cell(
         %(<p style="margin:0 0 14px;font-size:12px;letter-spacing:.1em;text-transform:uppercase;) +
         %(color:#94a3b8;font-weight:700;">Newly announced</p>) +
         %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>) +
         [
           ["KH", "Kira Holm", "Spotify", "#0f766e"],
           ["AB", "Ade Balogun", "Monzo", "#7c3aed"],
           ["MR", "Mireia Roca", "Adevinta", "#b91c1c"],
           ["JT", "Jun Takeda", "Mercari", "#c2410c"]
         ].map { |initials, name, org, color|
           %(<td width="126" align="center" valign="top">) +
           %(<img src="#{nl_avatar(initials, color)}" width="64" height="64" alt="#{name}" ) +
           %(style="display:block;margin:0 auto 8px;border-radius:50%;">) +
           %(<p style="margin:0;font-size:13px;font-weight:600;color:#0f172a;">#{name}</p>) +
           %(<p style="margin:2px 0 0;font-size:12px;color:#94a3b8;">#{org}</p></td>)
         }.join + %(</tr></table>), "6px 32px 20px"
       ) +
       nl_cell(
         [["10:00", "Governance without gatekeeping", "Workshop · 90 min"],
          ["13:30", "Measuring adoption you can't instrument", "Talk · 40 min"],
          ["15:15", "Contribution models that survive a reorg", "Workshop · 90 min"]]
           .map { |time, title, kind|
             %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ) +
             %(style="border-top:1px solid #e8edf3;"><tr>) +
             %(<td width="64" valign="top" style="padding:14px 0;font-size:13px;font-weight:700;) +
             %(color:#0f766e;">#{time}</td><td valign="top" style="padding:14px 0;">) +
             %(<p style="margin:0;font-size:15px;color:#0f172a;">#{title}</p>) +
             %(<p style="margin:2px 0 0;font-size:12px;color:#94a3b8;">#{kind}</p>) +
             %(</td></tr></table>)
           }.join, "0 32px 8px"
       ) +
       nl_cell(
         %(<p style="margin:0;font-size:13px;color:#9a3412;font-weight:600;">) +
         %(Early bird ends Friday — tickets go up €150 after that.</p>), "16px 32px", "#fff7ed"
       ) +
       nl_cell(nl_button("Book your ticket", "#0f766e"), "22px 32px 30px") +
       nl_footer("DesignOps Summit, Weena 505, Rotterdam. You're on this list as a past " \
                 "attendee or speaker.")
     )],

    # ── Editorial: serif, cream, one big pull quote ──────────────────────────
    ["Type Collective", "letters@type-collective.org", "press", "marketing",
     "Issue 47 — the case against the variable font",
     "Mara on why range is not the same thing as intent.",
     %w[Press], 12, true,
     nl_wrap(
       "Mara on why range is not the same thing as intent.",
       nl_cell(
         %(<p style="margin:0;font-family:Georgia,'Times New Roman',serif;font-size:13px;) +
         %(letter-spacing:.34em;text-transform:uppercase;color:#8a7f70;">Type Collective</p>) +
         %(<p style="margin:8px 0 0;font-family:Georgia,serif;font-size:13px;color:#a89c8c;">) +
         %(Issue 47 &nbsp;·&nbsp; August 2026</p>), "34px 40px 0"
       ) +
       nl_cell(
         %(<h1 style="margin:0 0 18px;font-family:Georgia,'Times New Roman',serif;font-size:32px;) +
         %(line-height:1.22;color:#221d16;font-weight:400;">The case against the variable font</h1>) +
         %(<p style="margin:0 0 16px;font-family:Georgia,serif;font-size:16px;line-height:1.75;) +
         %(color:#3f382e;">A variable font gives you every weight between 100 and 900. That ) +
         %(sounds like freedom, and for about a week it is. Then you open a file six months ) +
         %(later and find eleven weights in use, none of them chosen on purpose.</p>) +
         # A <div>, not a <blockquote>: the reader collapses generic blockquotes
         # into a "Quoted text" disclosure (quoteDetector strategy 1), which is
         # right for a reply chain and wrong for a magazine pull quote — on camera
         # the pull quote would arrive folded shut.
         %(<div style="margin:24px 0;padding:0 0 0 20px;border-left:3px solid #c9b89f;) +
         %(font-family:Georgia,serif;font-size:20px;line-height:1.5;color:#221d16;font-style:italic;">) +
         %(A range is not a decision. Somebody still has to make the decision, and a slider ) +
         %(is very good at postponing it.</div>) +
         %(<p style="margin:0;font-family:Georgia,serif;font-size:16px;line-height:1.75;) +
         %(color:#3f382e;">None of which is an argument against the technology. It's an ) +
         %(argument for shipping three named instances and hiding the axis.</p>),
         "24px 40px 10px"
       ) +
       nl_cell(
         %(<hr style="border:0;border-top:1px solid #e2d9c9;margin:0 0 20px;">) +
         %(<p style="margin:0 0 14px;font-family:Georgia,serif;font-size:12px;letter-spacing:.12em;) +
         %(text-transform:uppercase;color:#a89c8c;">Also in this issue</p>) +
         [["Releases", "Four new text families, two of them free for non-commercial work."],
          ["Interview", "Twenty years of lettering on shopfronts, with Halima Berger."]]
           .map { |kicker, text|
             %(<p style="margin:0 0 12px;font-family:Georgia,serif;font-size:15px;line-height:1.6;) +
             %(color:#3f382e;"><strong style="color:#221d16;">#{kicker}.</strong> #{text}</p>)
           }.join, "0 40px 12px"
       ) +
       nl_cell(nl_button("Read issue 47", "#221d16", "#f7f2e8", 4), "8px 40px 34px") +
       nl_footer("Type Collective is a non-profit. Post: PO Box 1147, Amsterdam. " \
                 "You subscribed at a meetup or through the site.", "#f2ebdd", "#a89c8c"),
       "#e8dfcd", "#faf6ec"
     )],

    # ── Promo: swatch grid built from table cells, no images at all ──────────
    ["Paperhouse", "atelier@paperhouse.fr", "billing", "finance",
     "Nouvelle collection — papiers texturés d'automne",
     "Douze teintes, dont quatre inédites. Échantillons gratuits jusqu'à vendredi.",
     %w[Vendor Finance], 16, true,
     nl_wrap(
       "Douze teintes, dont quatre inédites. Échantillons gratuits jusqu'à vendredi.",
       nl_cell(
         %(<p style="margin:0;font-size:13px;letter-spacing:.28em;text-transform:uppercase;) +
         %(color:#ffffff;">Paperhouse</p>), "24px 32px", "#1f2937"
       ) +
       %(<tr><td style="padding:0;">#{nl_remote(42, 600, 200, "L'atelier")}</td></tr>) +
       nl_cell(
         %(<h1 style="margin:0 0 12px;font-size:26px;line-height:1.25;color:#111827;">) +
         %(Papiers texturés — collection automne</h1>) +
         %(<p style="margin:0;font-size:15px;line-height:1.65;color:#4b5563;">) +
         %(Douze teintes en 120, 250 et 350 g/m². Les quatre nouvelles sont en bas ) +
         %(de la grille — le Vert Cendre part déjà vite.</p>), "28px 32px 18px"
       ) +
       nl_cell(
         %(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">) +
         [["#E7E1D5", "Ivoire"], ["#C9CBB8", "Vert Cendre"], ["#B9A48C", "Lin"], ["#8C7A66", "Tabac"],
          ["#6C7A89", "Ardoise"], ["#A8536A", "Grenat"], ["#3F4B5B", "Encre"], ["#D9A441", "Safran"]]
           .each_slice(4).map { |row|
             %(<tr>) + row.map { |hex, name|
               %(<td width="126" align="center" valign="top" style="padding:0 8px 16px 0;">) +
               %(<div style="height:78px;border-radius:8px;background:#{hex};) +
               %(border:1px solid rgba(0,0,0,.08);"></div>) +
               %(<p style="margin:8px 0 0;font-size:12px;color:#4b5563;">#{name}</p></td>)
             }.join + %(</tr>)
           }.join + %(</table>), "0 32px 6px"
       ) +
       nl_cell(
         %(<p style="margin:0 0 4px;font-size:14px;color:#111827;font-weight:600;">) +
         %(Échantillons gratuits jusqu'au vendredi</p>) +
         %(<p style="margin:0;font-size:13px;line-height:1.6;color:#6b7280;">) +
         %(Un jeu complet par client, expédié sous 48 h. Indiquez « ATELIER » à la commande.</p>),
         "16px 32px", "#f3f4f6"
       ) +
       nl_cell(nl_button("Voir la collection", "#1f2937"), "22px 32px 30px") +
       nl_footer("Paperhouse SARL, 8 rue de la Fonderie, 75011 Paris. Vous recevez cet email " \
                 "en tant que client professionnel.")
     )]
  ].freeze

  # ── Files on the demo threads ──────────────────────────────────────────────
  # Attachments are the one part of MX mail a body can't fake: the reading pane
  # shows a chip only if an Attachment row exists, and the download works only if
  # the bytes are in object storage. Both happen here. The upload is best effort —
  # on a machine with no Garage running (docker compose --profile storage up) the
  # rows still exist, so the chips and the list paperclip render; only the
  # download is unavailable, and the client reports that honestly.
  #
  #   subject => [[filename, content_type, body lines], ...]
  DEMO_FILES = {
    "Northwind packaging — dieline revisions" => [
      ["northwind-dieline-v3.pdf", "application/pdf",
       ["Northwind - structural dieline v3",
        "Box, 350gsm, litho + matt lamination.",
        "Changes from v2: tuck flap 3mm deeper; window moved 8mm to the spine."]],
      ["structural-engineer-notes.txt", "text/plain",
       ["Window shift takes the crop to 4mm at the tightest point.",
        "Recommend re-cropping the illustration rather than scaling it."]]
    ],
    "Lumen design system — component audit findings" => [
      ["lumen-component-audit.csv", "text/csv",
       ["component,in_figma,implemented,drift",
        "Button,yes,yes,low", "Input,yes,yes,high", "Select,yes,yes,high",
        "Checkbox,yes,yes,high", "Radio,yes,no,-", "Toast,yes,yes,medium"]]
    ],
    "Framewright — final invoice, Aurora signage" => [
      ["framewright-INV-3320.pdf", "application/pdf",
       ["Framewright Ltd - Invoice INV-3320",
        "Aurora signage, 12 panels, museum glass.",
        "Total 4,180.00 GBP - net 15."]]
    ],
    "Invoice NP-4471 — 30 days overdue" => [
      ["NP-4471-statement.pdf", "application/pdf",
       ["North Point Print - Statement",
        "Invoice NP-4471, raised 30 days ago.",
        "Amount outstanding 3,420.00 GBP."]]
    ],
    "Aurora rebrand — final logo lockups approved" => [
      ["aurora-lockups-final.pdf", "application/pdf",
       ["Aurora Health - primary mark, approved lockups",
        "01-06 horizontal, stacked, and icon-only.",
        "Minimum clear space: the height of the A."]],
      ["aurora-favicon-appicon.txt", "text/plain",
       ["favicon-16.png favicon-32.png favicon.svg",
        "appicon-1024.png appicon-180.png appicon-192.png"]]
    ]
  }.freeze

  # A real, valid one-page PDF — small enough to build by hand, correct enough
  # that Preview and the in-app viewer both open it. Keep the text ASCII: the
  # base-14 Helvetica encoding here has no glyph for an em dash, which renders as
  # a hole rather than an error.
  def tiny_pdf(lines)
    body = lines.each_with_index.map { |t, i|
      "BT /F1 13 Tf 40 #{700 - i * 22} Td (#{t.gsub(/([()\\])/, '\\\\\\1')}) Tj ET"
    }.join("\n")
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 792] /Contents 4 0 R " \
        "/Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{body.bytesize} >>\nstream\n#{body}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    out = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map { |obj, i|
      at = out.bytesize
      out << "#{i + 1} 0 obj\n#{obj}\nendobj\n"
      at
    }
    xref_at = out.bytesize
    out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
    out
  end

  def demo_file_bytes(filename, lines)
    filename.end_with?(".pdf") ? tiny_pdf(lines) : "#{lines.join("\n")}\n"
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  def demo_guard!
    return unless Rails.env.production?
    abort "demo:* tasks are demo data and must never run in production."
  end

  def address(display, email) = "#{display} <#{email}>"

  desc "Build/refresh the Brightfold MX demo workspace (idempotent)"
  task brightfold: :environment do
    demo_guard!
    t0 = Time.current

    puts "Brightfold demo — building #{BRIGHTFOLD_DOMAIN}…"

    # ── Org, domain, plan ────────────────────────────────────────────────────
    owner = User.find_or_create_by!(username: "sam") do |u|
      u.password = "password123"
      u.display_name = "Sam Brightfold"
      u.billing_email = "sam@brightfold.co"
      u.default_timezone = "Europe/London"
    end

    org = Organization.find_or_create_by!(slug: BRIGHTFOLD_SLUG) do |o|
      o.name = "Brightfold"
      o.owner = owner
      o.timezone = "Europe/London"
    end

    domain = Domain.find_or_create_by!(name: BRIGHTFOLD_DOMAIN) do |d|
      d.organization = org
    end
    # receiving_mail, not verified: the console shows a live domain rather than a
    # half-finished setup wizard.
    domain.update!(status: Domain::STATUS_RECEIVING_MAIL) unless domain.status == Domain::STATUS_RECEIVING_MAIL

    org.subscription || Subscription.create!(
      organization: org,
      plan: Plan.max,
      status: Subscription::STATUS_ACTIVE,
      current_period_ends_at: 1.year.from_now
    )

    # ── Team + mailboxes ─────────────────────────────────────────────────────
    roles = {
      owner: Membership::ROLE_OWNER,
      admin: Membership::ROLE_ADMIN,
      member: Membership::ROLE_MEMBER
    }
    members = {}
    TEAM.each do |username, display, role, title, local_part|
      user = User.find_or_create_by!(username: username) do |u|
        u.password = "password123"
        u.display_name = display
        u.billing_email = "#{username}@brightfold.co"
        u.default_timezone = "Europe/London"
      end
      user.update!(display_name: display) if user.display_name != display

      membership = Membership.find_or_create_by!(user: user, organization: org) do |m|
        m.role = roles.fetch(role)
        m.status = Membership::STATUS_ACTIVE
      end
      membership.update!(title: title) if membership.respond_to?(:title) && membership.title != title

      Mailbox.find_or_create_by!(domain: domain, local_part: local_part) do |mb|
        mb.membership = membership
      end
      members[username] = membership
    end

    SHARED_MAILBOXES.each do |local_part, owner_username|
      Mailbox.find_or_create_by!(domain: domain, local_part: local_part) do |mb|
        mb.membership = members.fetch(owner_username)
      end
    end
    puts "  team: #{members.size} members, #{domain.mailboxes.count} mailboxes"

    # ── Tags, views, spaces ──────────────────────────────────────────────────
    Tag.ensure_system_tags(org)
    View.ensure_system_views(org)
    Space.ensure_default_spaces(org)

    TAGS.each do |name, color|
      Tag.find_or_create_by!(organization: org, name: name) { |t| t.color = color }
    end
    all_tags = Tag.where(organization: org).to_a
    spaces = org.spaces.index_by(&:slug)

    # Staff the assigned-only spaces, or they read as empty in the console.
    [["sales", %w[sam mina]], ["finance", %w[mina sam]]].each do |slug, usernames|
      space = spaces[slug] or next
      usernames.each do |u|
        SpaceMembership.find_or_create_by!(space: space, membership: members.fetch(u))
      end
    end

    # ── Routing rules ────────────────────────────────────────────────────────
    [
      ["New business routing", "new-business@", [{ "type" => "add_tag", "value" => "New biz" },
                                                 { "type" => "assign", "value" => members["sam"].key }]],
      ["Billing routing",      "billing@",      [{ "type" => "add_tag", "value" => "Finance" },
                                                 { "type" => "assign", "value" => members["mina"].key }]],
      ["Support routing",      "support@",      [{ "type" => "add_tag", "value" => "Studio" }]],
      ["Press routing",        "press@",        [{ "type" => "add_tag", "value" => "Press" },
                                                 { "type" => "assign", "value" => members["aria"].key }]]
    ].each_with_index do |(name, match, actions), i|
      Rule.find_or_create_by!(organization: org, name: name) do |r|
        r.conditions = [{ "field" => "to", "operator" => "contains", "value" => match }]
        r.actions = actions
        r.position = i
      end
    end

    # ── Threads ──────────────────────────────────────────────────────────────
    now = Time.current
    built = 0
    # Who the studio side of a thread is "from". Falls back to the founder when a
    # thread is unassigned — an unowned reply still needs a plausible sender.
    studio_names = TEAM.to_h { |username, display, _r, _t, _lp| [username, display] }

    THREADS.each_with_index do |(contact_id, mailbox, space_slug, subject, tag_names, assignee, opts), idx|
      display, email = CONTACTS.fetch(contact_id)
      from = address(display, email)
      to = "#{mailbox}@#{BRIGHTFOLD_DOMAIN}"
      opened_at = now - (opts[:days] || 0).days - (opts[:hours] || 0).hours
      replies = opts[:replies] || []
      last_body = replies.last || opts[:body]

      conv = Conversation.find_or_initialize_by(organization: org, subject: subject)
      conv.assign_attributes(
        domain: domain,
        space: spaces[space_slug],
        from_address: from,
        to_address: to,
        status: opts[:status] || Conversation::STATUS_OPEN,
        read: opts.fetch(:read, true),
        snippet: last_body.to_s.tr("\n", " ").squeeze(" ").truncate(140)
      )
      conv.save!

      # Rebuild the thread's messages so re-running picks up edited copy rather
      # than leaving the first version in place forever.
      conv.messages.destroy_all

      replier = assignee || "sam"
      studio_from = address(studio_names.fetch(replier, "Brightfold"), "#{replier}@#{BRIGHTFOLD_DOMAIN}")

      bodies = [[opts[:body], true]] + replies.map { |r| [r, false] }
      bodies.each_with_index do |(body, inbound), i|
        # Space replies out across the thread's life so timestamps read naturally.
        sent_at = opened_at + (i * 47).minutes
        Message.create!(
          conversation: conv,
          organization: org,
          from_address: inbound ? from : studio_from,
          to_address: inbound ? to : from,
          subject: subject,
          body_plain: body,
          body_html: body.split("\n\n").map { |p| "<p>#{ERB::Util.html_escape(p).gsub("\n", "<br>")}</p>" }.join,
          is_inbound: inbound,
          is_draft: false,
          message_id_header: "<bf-#{idx}-#{i}@#{BRIGHTFOLD_DOMAIN}>",
          created_at: sent_at,
          updated_at: sent_at
        )
      end

      conv.update_columns(created_at: opened_at, updated_at: opened_at + (bodies.size - 1) * 47 * 60)

      # Labelling is something a person does, not a default: a real inbox is
      # mostly unlabelled and the chips mean nothing when every row has one. Only
      # every fourth thread carries its tags — deterministic, so re-runs don't
      # reshuffle which. Routine volume and newsletters get none at all.
      conv.conversation_tags.destroy_all
      if (idx % 4).zero?
        tag_names.each do |raw|
          name = raw.delete('"')
          tag = all_tags.find { |t| t.name == name }
          next unless tag
          ConversationTag.find_or_create_by!(conversation: conv, tag: tag)
        end
      end

      if assignee && (membership = members[assignee])
        ConversationAssignee.find_or_create_by!(conversation: conv, membership: membership)
      end

      built += 1
    end

    # ── Background volume ────────────────────────────────────────────────────
    # Deterministic spacing rather than rand(): re-running must not reshuffle the
    # inbox between takes of the same video.
    routine = 0
    ROUTINE.each_with_index do |(sender, sender_email, mailbox, space_slug, subject_tpl, body, _tag_names, count), t|
      count.times do |n|
        subject = format(subject_tpl, (n + 1) * 7 + t)
        # Fan the series out across ~9 weeks, offset per template so the list
        # interleaves instead of arriving in blocks.
        sent_at = now - ((n * 9) + (t * 2) + 1).days - ((t * 3 + n * 5) % 11).hours
        from = address(sender, sender_email)
        to = "#{mailbox}@#{BRIGHTFOLD_DOMAIN}"

        conv = Conversation.find_or_initialize_by(organization: org, subject: subject)
        conv.assign_attributes(
          domain: domain, space: spaces[space_slug],
          from_address: from, to_address: to,
          status: Conversation::STATUS_OPEN,
          # The two newest of each series stay unread — that's how these actually
          # accumulate — the rest are read.
          read: n >= 2,
          snippet: body.tr("\n", " ").squeeze(" ").truncate(140)
        )
        conv.save!
        conv.messages.destroy_all
        Message.create!(
          conversation: conv, organization: org,
          from_address: from, to_address: to, subject: subject,
          body_plain: body,
          body_html: body.split("\n\n").map { |p| "<p>#{ERB::Util.html_escape(p)}</p>" }.join,
          is_inbound: true, is_draft: false,
          message_id_header: "<bf-r#{t}-#{n}@#{BRIGHTFOLD_DOMAIN}>",
          created_at: sent_at, updated_at: sent_at
        )
        conv.update_columns(created_at: sent_at, updated_at: sent_at)

        conv.conversation_tags.destroy_all  # untriaged background volume: no labels
        routine += 1
      end
    end

    # ── Newsletters ──────────────────────────────────────────────────────────
    NEWSLETTERS.each_with_index do |(sender, sender_email, mailbox, space_slug, subject,
                                     preheader, _tag_names, days, read, html), n|
      sent_at = now - days.days - ((n * 5) % 9).hours
      from = address(sender, sender_email)
      to = "#{mailbox}@#{BRIGHTFOLD_DOMAIN}"

      conv = Conversation.find_or_initialize_by(organization: org, subject: subject)
      conv.assign_attributes(
        domain: domain, space: spaces[space_slug],
        from_address: from, to_address: to,
        status: Conversation::STATUS_OPEN,
        read: read,
        # The preheader IS the snippet a real client shows — that's what senders
        # write it for. Stripping the tables for a snippet gives nav-link soup.
        snippet: preheader
      )
      conv.save!
      conv.messages.destroy_all
      Message.create!(
        conversation: conv, organization: org,
        from_address: from, to_address: to, subject: subject,
        body_plain: "#{preheader}\n\nView this email in your browser: https://example.com/view",
        body_html: html,
        is_inbound: true, is_draft: false,
        message_id_header: "<bf-n#{n}@#{BRIGHTFOLD_DOMAIN}>",
        created_at: sent_at, updated_at: sent_at
      )
      conv.update_columns(created_at: sent_at, updated_at: sent_at)

      conv.conversation_tags.destroy_all  # nobody labels newsletters
    end

    # ── Files ────────────────────────────────────────────────────────────────
    storage = begin
      S3StorageService.new
    rescue StandardError => e
      puts "  storage: #{e.class} — attachment rows will have no bytes " \
           "(docker compose --profile storage up)"
      nil
    end

    files = 0
    DEMO_FILES.each do |subject, specs|
      conv = org.conversations.find_by(subject: subject) or next
      msg = conv.messages.order(:id).first or next
      msg.attachments.destroy_all # idempotent, like the threads themselves

      specs.each do |filename, content_type, lines|
        data = demo_file_bytes(filename, lines)
        storage_key = begin
          storage&.upload(data, filename: filename, content_type: content_type,
                                organization_key: org.key)
        rescue StandardError => e
          Rails.logger.warn("[demo] upload failed for #{filename}: #{e.message}")
          nil
        end
        Attachment.create!(
          message: msg, organization: org,
          filename: filename, content_type: content_type,
          size_bytes: data.bytesize, storage_key: storage_key
        )
        files += 1
      end
    end
    puts "  files: #{files} attachments on #{DEMO_FILES.size} threads" \
         "#{storage ? ' (bytes uploaded)' : ' (metadata only)'}"

    puts "  newsletters: #{NEWSLETTERS.size} HTML"
    puts "  threads: #{built} featured + #{routine} routine " \
         "(#{org.conversations.count} total, #{org.conversations.where(read: false).count} unread)"
    puts "  messages: #{Message.where(organization: org).count}"
    puts "  spaces: #{org.spaces.pluck(:slug).join(', ')}"
    puts "\nDone in #{(Time.current - t0).round(1)}s."
    puts "Log in at http://localhost:4173 — any of #{TEAM.map(&:first).join(' / ')}, password123"
  end

  desc "Delete leftover e2e-console-*.test domains"
  task purge_e2e: :environment do
    demo_guard!
    scope = Domain.where("name LIKE 'e2e-console-%.test'")
    names = scope.pluck(:name)
    if names.empty?
      puts "No e2e-console-*.test domains found."
      next
    end
    puts "Deleting #{names.size} domain(s): #{names.join(', ')}"
    scope.destroy_all
    puts "Done."
  end

  desc "purge_e2e, then rebuild Brightfold from scratch"
  task reset: :environment do
    demo_guard!
    if (org = Organization.find_by(slug: BRIGHTFOLD_SLUG))
      puts "Destroying existing Brightfold org…"
      org.destroy!
    end
    Rake::Task["demo:purge_e2e"].invoke
    Rake::Task["demo:brightfold"].invoke
  end
end
