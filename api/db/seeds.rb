# Inbox2 — Seed data for local development (spec 17.3.1)
# Run with: bin/rails db:seed
#
# Email content adapted from the Enron Email Corpus (public domain),
# originally released by the FERC and hosted by CMU.

puts "Seeding plans..."
Plan.seed_defaults!

# Plans are real configuration (subscription tiers) and belong in every
# environment. Everything below is DEMO data (the Enron-derived demo org, users,
# conversations) and must never land in production. The prod deploy only ever
# runs `db:prepare` (no seed) — this guard is belt-and-suspenders for a stray
# manual `db:seed`. Override with ALLOW_DEMO_SEED=1 only if you really mean it.
if Rails.env.production? && !ENV["ALLOW_DEMO_SEED"]
  puts "Production environment — seeded plans only, skipping all demo data."
  puts "(set ALLOW_DEMO_SEED=1 to force demo seeding.)"
  return
end

puts "Seeding demo account..."
owner = User.find_or_create_by!(username: "demo") do |u|
  u.password = "password123"
  u.display_name = "Vince Kaminski"
  u.billing_email = "vince@external-email.com"
  u.default_timezone = "America/Chicago"
end

puts "Seeding organization..."
org = Organization.find_or_create_by!(slug: "acme-corp") do |o|
  o.name = "Acme Corp"
  o.owner = owner
  o.timezone = "America/Chicago"
end

# The org's domain (first-class Domain).
Domain.find_or_create_by!(name: "acme.com") do |d|
  d.organization = org
  d.status = Domain::STATUS_VERIFIED
end

# Subscribe the org to the paid plan for full features.
org.subscription || Subscription.create!(
  organization: org,
  plan: Plan.max,
  status: Subscription::STATUS_ACTIVE,
  current_period_ends_at: 1.year.from_now
)

# Owner membership
Membership.find_or_create_by!(user: owner, organization: org) do |m|
  m.role = Membership::ROLE_OWNER
  m.status = Membership::STATUS_ACTIVE
end

puts "Seeding team members..."
members_data = [
  { username: "louise", display_name: "Louise Kitchen", email: "louise@external.com", role: Membership::ROLE_ADMIN },
  { username: "jeff", display_name: "Jeff Shankman", email: "jeff@external.com", role: Membership::ROLE_ADMIN },
  { username: "sarah", display_name: "Sarah Chen", email: "sarah@external.com", role: Membership::ROLE_MEMBER },
  { username: "alex", display_name: "Alex Kim", email: "alex@external.com", role: Membership::ROLE_MEMBER },
  { username: "maria", display_name: "Maria Lopez", email: "maria@external.com", role: Membership::ROLE_MEMBER },
  { username: "shirley", display_name: "Shirley Crenshaw", email: "shirley@external.com", role: Membership::ROLE_MEMBER },
  { username: "stinson", display_name: "Stinson Gibner", email: "stinson@external.com", role: Membership::ROLE_MEMBER },
  { username: "katherine", display_name: "Katherine Walker", email: "katherine@external.com", role: Membership::ROLE_MEMBER }
]

members = {}
members_data.each do |data|
  user = User.find_or_create_by!(username: data[:username]) do |u|
    u.password = "password123"
    u.display_name = data[:display_name]
    u.billing_email = data[:email]
  end
  membership = Membership.find_or_create_by!(user: user, organization: org) do |m|
    m.role = data[:role]
    m.status = Membership::STATUS_ACTIVE
  end
  members[data[:username]] = { user: user, membership: membership }
end

puts "Seeding tags..."
# System tags (priority) — cannot be deleted by users
Tag.ensure_system_tags(org)

tags_data = [
  { name: "Finance", color: "#8090a8" },
  { name: "Support", color: "#b8a0b8" },
  { name: "Dev", color: "#9890b0" },
  { name: "Billing", color: "#c8a898" },
  { name: "VIP", color: "#d4a843" },
  { name: "HR", color: "#a8c098" },
  { name: "Legal", color: "#c0a0a0" },
  { name: "Ops", color: "#90a8c0" }
]

tags = Tag.where(organization: org).to_a
tags_data.each do |data|
  tag = Tag.find_or_create_by!(organization: org, name: data[:name]) do |t|
    t.color = data[:color]
  end
  tags << tag unless tags.any? { |t| t.id == tag.id }
end

puts "Seeding views..."
View.ensure_system_views(org)

puts "Seeding routing rules..."
Rule.find_or_create_by!(organization: org, name: "Finance routing") do |r|
  r.conditions = [{ "field" => "to", "operator" => "contains", "value" => "finance@" }]
  r.actions = [{ "type" => "add_tag", "value" => "Finance" }, { "type" => "assign", "value" => members["sarah"][:membership].key }]
  r.position = 0
end

Rule.find_or_create_by!(organization: org, name: "Support routing") do |r|
  r.conditions = [{ "field" => "to", "operator" => "contains", "value" => "support@" }]
  r.actions = [{ "type" => "add_tag", "value" => "Support" }]
  r.position = 1
end

Rule.find_or_create_by!(organization: org, name: "HR routing") do |r|
  r.conditions = [{ "field" => "to", "operator" => "contains", "value" => "hr@" }]
  r.actions = [{ "type" => "add_tag", "value" => "HR" }]
  r.position = 2
end

puts "Seeding conversations with Enron email content..."

# Helper to create conversations with messages
def seed_conversation(org:, data:, tags:, members:, all_tags:)
  conv = Conversation.find_or_create_by!(organization: org, subject: data[:subject]) do |c|
    c.from_address = data[:from]
    c.to_address = data[:to]
    c.status = data[:status] || Conversation::STATUS_OPEN
    c.snippet = data[:messages].last[:body].truncate(100)
  end

  data[:messages].each_with_index do |msg_data, i|
    Message.find_or_create_by!(
      conversation: conv,
      organization: org,
      from_address: msg_data[:from],
      body_plain: msg_data[:body]
    ) do |m|
      m.to_address = msg_data[:to] || data[:to]
      m.subject = data[:subject]
      m.is_inbound = !msg_data[:from].end_with?("@acme.com")
      m.is_draft = msg_data[:draft] == true
      m.message_id_header = "<seed-#{conv.id}-#{i}@acme.com>"
    end
  end

  # `tags` is the gated list the caller decided this thread actually gets — most
  # threads get none, so the list doesn't read as a wall of chips.
  tags.each do |tag_name|
    tag = all_tags.find { |t| t.name == tag_name }
    conv.tags << tag if tag && !conv.tags.include?(tag)
  end

  # Assign if specified
  if data[:assign_to]
    membership = members.dig(data[:assign_to], :membership)
    conv.assignees << membership if membership && !conv.assignees.include?(membership)
  end

  conv
end

conversations_data = [
  # 1. Board presentation prep — multi-message thread
  {
    subject: "Q4 Board Presentation — Updated Deck",
    from: "mollie.gustafson@partner.io",
    to: "exec@acme.com",
    tags: ["Finance", "VIP"],
    assign_to: "louise",
    messages: [
      {
        from: "mollie.gustafson@partner.io",
        body: <<~BODY
          Please find attached the board presentation for the Q4 expansion review. Should you have comments or edits, please contact Chris or me via email or fax.

          The deck covers three main areas: (1) revenue projections by segment, (2) headcount growth plan for the Austin office, and (3) updated competitive landscape analysis following the Dynegy announcement last week.

          We've incorporated the feedback from the September dry run — the regional breakdown slides now have larger fonts and units of measure on every chart. The financial summary has been restructured to lead with operating margin rather than gross revenue, per Louise's suggestion.

          Thank you.
          Mollie Gustafson
          Phone: 503/464-3740
        BODY
      },
      {
        from: "louise@acme.com",
        body: <<~BODY
          Mollie — thanks. It looks very good. I made a few minor changes this evening to add units of measure to the remaining slides that were missing them.

          I'll have Terry and Steve review the master copy and shoot it back to you on Monday, probably around mid-morning, so you'll know of these minor changes. Each one is intended to enhance visibility without changing any content.

          Terry will be in touch, or you can reach her at ext. 36910 if necessary.

          Again, thanks. Have a great weekend.
          Louise
        BODY
      },
      {
        from: "vince@acme.com",
        body: <<~BODY
          Louise, Mollie —

          The competitive analysis section looks solid. One suggestion: can we add a slide showing our market share trajectory over the past 8 quarters? The board asked about this specifically at the last meeting and I think having the trend line will preempt questions.

          I can pull the data from our analytics dashboard if that helps. Let me know.

          Vince
        BODY
      }
    ]
  },

  # 2. Tag line contest — company culture
  {
    subject: "Tag Line Contest Results — And the Winner Is...",
    from: "marketing@acme.com",
    to: "all-hands@acme.com",
    tags: ["Ops"],
    messages: [
      {
        from: "marketing@acme.com",
        body: <<~BODY
          The judges are happy to announce that Colin Tonks is the winner of the $250 tag line contest! Of Colin's submissions, two ideas were expanded upon and resulted in the following tag line:

          "Acme — Smarter Operations. Online. Worldwide."

          Congratulations to Colin for providing the catalyst that resulted in a unique, catchy, concise, and meaningful tag line for our strategic effort.

          Thanks to all who participated in our contest. We received over 80 submissions, making a decision on only one winner a real challenge. Several other submissions received serious consideration and were discussed at length.

          We will be incorporating the new tag line into all marketing materials beginning next month. If you have existing presentations or client-facing documents, please update them at your earliest convenience. The brand assets folder on the shared drive has been updated with new templates.

          — The Marketing Team
        BODY
      }
    ]
  },

  # 3. Thanksgiving company-wide message
  {
    subject: "Thanksgiving Holiday — Office Hours & Gratitude",
    from: "vince@acme.com",
    to: "all-hands@acme.com",
    status: Conversation::STATUS_ARCHIVED,
    messages: [
      {
        from: "vince@acme.com",
        body: <<~BODY
          As we approach the Thanksgiving holiday, I want to take this opportunity to wish you and yours a safe and happy holiday.

          With the recent events in our industry, giving thanks this year has taken on a whole new meaning. We can be thankful for our team's resilience, our customers' loyalty, and the progress we've made together this year.

          I recognize that we are working through some challenging times and that everyone in the organization is working hard. Thank you for your continued dedication and commitment. It's appreciated more than you know.

          A few logistics: The office will close at 2:00 PM on Wednesday and reopen Monday morning. The on-call rotation for the holiday weekend has been posted in the #ops channel. If you're on call, thank you — and know that comp time will be available the following week.

          Please take time to be with your families, rest, and recharge. We have an exciting Q1 ahead of us.

          Happy Thanksgiving,
          Vince
        BODY
      }
    ]
  },

  # 4. Fortune conference panel — external opportunity
  {
    subject: "Fortune Conference — Panel Change (Higher Profile)",
    from: "pattie.sellers@fortune.com",
    to: "louise@acme.com",
    tags: ["VIP"],
    assign_to: "louise",
    messages: [
      {
        from: "karen.james@acme.com",
        to: "louise@acme.com",
        body: <<~BODY
          Louise — just got a call from Pattie Sellers with Fortune Magazine. They'd like to change your panel for the October conference.

          Instead of speaking on "Navigating Globally," they'd like you to speak on the panel "Pushing the Boundaries." It's a more high-profile panel — it opens the session on Thursday morning.

          Other speakers include Andrea Jung, CEO of Avon, and Lynn Forester, Co-CEO/Chairman of FirstMark Communications (she raised $1 billion in private equity and is building a broadband network in Europe). Maria Bartiromo of CNBC will be the moderator.

          I think this is a much better fit for you and the topics you've been speaking about recently — operational innovation, building high-performance teams, and scaling technology platforms.

          Let me know if you'd like to accept and I'll coordinate with Pattie's office on logistics.

          Karen
        BODY
      },
      {
        from: "louise@acme.com",
        to: "karen.james@acme.com",
        body: <<~BODY
          Karen — absolutely, let's do it. The "Pushing the Boundaries" panel is a much better fit.

          Can you find out what format they're expecting? Last time it was a 10-minute prepared talk followed by 20 minutes of moderated Q&A. I'd like to know if that's changed so I can prepare accordingly.

          Also, please check if they can accommodate a plus-one for the Thursday evening reception. I'd like to bring Jeff — he's been working on the international expansion strategy and it would be good for him to network with that crowd.

          Thanks,
          Louise
        BODY
      }
    ]
  },

  # 5. Budget allocations — finance thread
  {
    subject: "Re: Budget Allocations for COOA — Dedicated Resources",
    from: "kent.castleman@acme.com",
    to: "finance@acme.com",
    tags: ["Finance"],
    assign_to: "sarah",
    messages: [
      {
        from: "kent.castleman@acme.com",
        body: <<~BODY
          Louise,

          Embedded in these allocations are several functions for which our division receives 100% dedicated resources (legal, HR, PR, etc.). Every 100% dedicated resource should be presented in its own responsibility center — in that way it becomes "controllable" and measurable. Today it is buried in an indirect allocation.

          This approach will isolate the truly indirect allocations and allow us to better manage the amount and appropriateness of these expenses. We plan to push this topic with respect to all allocations which hit our division from the parent company.

          Specifically, I'd recommend we break out:
          • Legal counsel (currently $340K buried in G&A)
          • Dedicated HR business partner ($180K in shared services)
          • PR/Comms support ($95K in marketing overhead)

          Once isolated, we can benchmark these against industry standards and make informed decisions about whether to bring them in-house or renegotiate the service agreements.

          Kent Castleman
        BODY
      },
      {
        from: "louise@acme.com",
        body: <<~BODY
          Kent — good thinking. I agree we need visibility into these dedicated costs.

          Can you put together a one-pager showing the current state vs. proposed breakout? I'd like to present this at the next finance committee meeting on the 22nd.

          Also, have you spoken with the controller's office about the timeline for migrating these line items? We're in the middle of the SAP transition and I don't want to create more work for their team during the cutover.

          Louise
        BODY
      }
    ]
  },

  # 6. Management announcement
  {
    subject: "Management Announcement — Organizational Changes",
    from: "vince@acme.com",
    to: "all-hands@acme.com",
    tags: ["HR"],
    messages: [
      {
        from: "vince@acme.com",
        body: <<~BODY
          As you are all aware, our platform division has grown to be a significant part of Acme Corp. The partnership announcement this week confirms the tremendous inroads we have made in the enterprise market.

          We expect this deal to be a springboard for enabling us to accomplish even greater things. Because we believe that the platform is integral to our success, it is becoming increasingly important for greater interaction among senior management, corporate leadership, and our regional offices.

          To that end, I'm pleased to announce the following organizational changes effective immediately:

          • Louise Kitchen will assume the role of VP of Operations, overseeing both the Houston and Austin teams.
          • Jeff Shankman will lead the new International Business Development group, focusing on European and Asian markets.
          • Stinson Gibner will take over as head of the Research division, reporting directly to me.

          Please join me in congratulating each of them. These changes reflect the depth of talent we have in this organization and position us well for the growth ahead.

          I will be scheduling town halls in each office over the next two weeks to discuss these changes and answer questions. In the meantime, please don't hesitate to reach out to me or any of the leadership team.

          Vince
        BODY
      }
    ]
  },

  # 7. Carnegie Mellon recruiting
  {
    subject: "Carnegie Mellon Candidates — Interview Scheduling",
    from: "shirley@acme.com",
    to: "hr@acme.com",
    tags: ["HR"],
    assign_to: "shirley",
    messages: [
      {
        from: "shirley@acme.com",
        body: <<~BODY
          Kristin,

          We are sending the interview request form information to Molly Magee to bring the following two candidates in for interviews:

          • Frank (Feng) Qian — PhD candidate, specializing in quantitative modeling. Strong publication record and a summer internship at Goldman. Vince spoke with him at the career fair and was impressed.
          • Punit Rawal — MS in Computer Science with a focus on distributed systems. Built a real-time data processing pipeline for his thesis project that handles 2M events/sec.

          We have no further interest in the following two candidates. Do you handle contacting them, or should we send the standard decline letter from our end?

          • Heap-Ho Tan
          • Kyubaek Heo

          Please let me know the timeline for scheduling. Vince would like to have the first-round interviews completed before the holiday break if possible.

          Thanks,
          Shirley
        BODY
      },
      {
        from: "kristin.davis@external.com",
        body: <<~BODY
          Shirley,

          I'll get the interview requests processed today. For Frank and Punit, I'd suggest scheduling them for the week of the 14th — that gives us two weeks before the break.

          I can handle the decline communications for the other two candidates. We'll send the standard letter with an invitation to reapply next cycle.

          One question: should we fly Frank in from Pittsburgh or do a video call for the first round? Given the travel budget situation, I want to make sure we have approval before booking flights.

          Kristin
        BODY
      }
    ]
  },

  # 8. Expense report processing deadline
  {
    subject: "Cutoff for Processing Invoices and Expense Reports",
    from: "accounting@acme.com",
    to: "all-hands@acme.com",
    tags: ["Finance", "Ops"],
    messages: [
      {
        from: "accounting@acme.com",
        body: <<~BODY
          Please note that there is a cutoff date for processing all invoices and expense reports in the current system. The cutoff date is next Thursday, June 15th.

          Beginning July 1, all invoices and expense reports will be processed in the new SAP system and all of the coding will change. Your assistants should have attended a training class to obtain the new coding information. If anyone on your team missed the training, please contact Accounts Payable immediately — we're running two make-up sessions next week.

          Any invoices and expense reports submitted after June 15th will be held and will not be processed until July 5th, after the SAP go-live date.

          Key reminders:
          • Receipts over $25 must be scanned and attached (photos from your phone are fine)
          • International travel expenses must include the exchange rate used
          • Client entertainment requires the names of all attendees and business purpose
          • Mileage reimbursements need odometer readings or a Google Maps screenshot

          Please submit everything you have outstanding as soon as possible. We anticipate a high volume of submissions this week and processing times may be longer than usual.

          — Accounts Payable
        BODY
      }
    ]
  },

  # 9. Risk and return analysis — technical discussion
  {
    subject: "Understanding Risk and Return of an Insurance Portfolio",
    from: "tanya.tamarchenko@acme.com",
    to: "vince@acme.com",
    tags: ["Finance"],
    messages: [
      {
        from: "tanya.tamarchenko@acme.com",
        body: <<~BODY
          Hi Vince,

          I am enclosing a report on my thoughts about risk and return behavior of an insurance portfolio. Your input on this will be very helpful.

          I have given Stinson a copy of this report and am working with him towards improving it. In the meantime, I happened to mention this idea in a meeting with David Porter, Brad Blesie, and David Hoog, and there seems to be some interest in understanding how this works. In fact, David Hoog subsequently reviewed this with me and suggested some changes, which have been included in this version.

          The idea here is simple: we model the insurance book as a portfolio of correlated binary risks, where each policy either triggers a payout or doesn't. By treating the aggregate loss distribution as a mixture of conditionally independent Bernoulli trials, we can derive closed-form expressions for VaR and expected shortfall that are much faster to compute than the Monte Carlo approach we've been using.

          The key insight is that correlation between policies (e.g., geographic concentration in hurricane zones) can be captured through a small number of systematic factors, similar to how credit portfolio models work.

          I'd love to discuss this when you have 30 minutes.

          Tanya
        BODY
      },
      {
        from: "vince@acme.com",
        body: <<~BODY
          Tanya,

          This is excellent work. The factor-based decomposition is elegant and I can see why David was interested.

          Two thoughts:

          1. Have you tested the sensitivity of the VaR estimates to the number of systematic factors? In the credit world, going from 1 to 3 factors can change tail estimates significantly. I'd want to see a stability analysis before we present this to the risk committee.

          2. The closed-form approach assumes the factor loadings are constant across the book. Is that realistic for our portfolio, given the mix of property, casualty, and specialty lines?

          Let's set up time next week. I'll ask Stinson to join — he's been thinking about similar problems in a different context.

          Vince
        BODY
      }
    ]
  },

  # 10. India market entry — international thread
  {
    subject: "India Status and Update — Market Entry Assessment",
    from: "heidi.hellman@acme.com",
    to: "intl@acme.com",
    tags: ["Ops", "VIP"],
    assign_to: "jeff",
    messages: [
      {
        from: "heidi.hellman@acme.com",
        body: <<~BODY
          I had a meeting today with Milind Laad (Financial Controller), Anand S. (Manager, Accounts), and our local commercial associate from the Indian office regarding their expected transactions and operational readiness. We based the discussion around the market entry checklist. Here is a summary:

          India operations are in the process of evaluating potential deals but have not signed any contracts yet. The team believes that in the near term we will only be doing a few transactions per month, but the pipeline is growing. Key findings:

          1. REGULATORY: The Reserve Bank of India requires prior approval for derivatives transactions involving foreign entities. Our legal team in Mumbai is working through the application — expect 6-8 weeks.

          2. BANKING: We have established accounts with ICICI Bank and HDFC. Wire transfers are functional but take 3-4 business days due to correspondent banking requirements.

          3. TAX: Transfer pricing documentation needs to be in place before the first inter-company transaction. Milind is working with Deloitte Mumbai on this.

          4. SYSTEMS: The mid and back office functions are being set up. We need SAP access provisioned for the Mumbai team — I've submitted the request but it's been sitting in the queue for two weeks.

          5. HEADCOUNT: We currently have 4 people on the ground. Milind recommends we hire 2 additional analysts and 1 operations specialist before we start trading.

          I'll send a more detailed written report by Friday.

          Heidi
        BODY
      }
    ]
  },

  # 11. Industry association merger
  {
    subject: "HEA / NESA Merger — Your Input Needed",
    from: "steve.becker@industry-assoc.org",
    to: "info@acme.com",
    tags: ["Legal"],
    messages: [
      {
        from: "steve.becker@industry-assoc.org",
        body: <<~BODY
          Fellow HEA Members,

          Please read the attached letter carefully and forward any comments or suggestions you may have to the HEA office. Your input in this regard is critical to the HEA continuing to serve its members.

          As many of you know, the boards of both the Houston Energy Association and the National Energy Services Association have been in discussions about a potential merger. The rationale is straightforward: our memberships overlap significantly, our missions are complementary, and a combined organization would have greater lobbying power in Washington and Austin.

          The proposed timeline is:
          • Member comment period: Now through October 15
          • Special member vote: November board meeting
          • Integration (if approved): January 1 of next year

          Key questions we'd like your feedback on:
          1. Should dues remain at current HEA levels or move to the higher NESA structure?
          2. How should board representation be allocated between legacy HEA and NESA members?
          3. Are there specific programs from either organization that you consider essential to preserve?

          Steve Becker, President
          Houston Energy Association
          Phone: (713) 651-0551
        BODY
      }
    ]
  },

  # 12. IT/Risk operations report
  {
    subject: "Market Risk / Operational Risk Report — Daily Issues Log",
    from: "stinson@acme.com",
    to: "ops@acme.com",
    tags: ["Ops"],
    assign_to: "stinson",
    messages: [
      {
        from: "stinson@acme.com",
        body: <<~BODY
          Attached below is a compilation of operational and information technology issues that affect the timeliness, effectiveness, and accuracy of the daily risk management analysis.

          Daily, we aggregate information regarding the origin of these issues to better diagnose where time, money, and resources should be allocated to improve information flow.

          Summary for today:
          • Database replication lag peaked at 47 seconds during the morning batch (threshold: 10s). Root cause: the overnight ETL job ran 2 hours late due to a schema migration on the source system. Resolved at 8:42 AM.
          • Two users reported stale data in the risk dashboard between 7:15 and 8:45 AM. This was a downstream effect of the replication issue above.
          • The new Monte Carlo engine completed in 12 minutes, down from 28 minutes last week. The GPU optimization is paying off.
          • Pending: we still need sign-off from InfoSec on the new API gateway configuration before we can deploy the real-time feed to production.

          Please call me if you have any questions regarding this document.

          Stinson Gibner
        BODY
      }
    ]
  },

  # 13. California regulatory update
  {
    subject: "California Regulatory Update — Assembly Vote & Implications",
    from: "kristin.walsh@external-research.com",
    to: "exec@acme.com",
    tags: ["Legal", "Urgent"],
    messages: [
      {
        from: "kristin.walsh@external-research.com",
        body: <<~BODY
          For questions or comments regarding this report, please contact Britt Whitman at ext. 5-4014 or me directly.

          EXECUTIVE SUMMARY

          The regulatory reform bill passed the Assembly late last night by a 41-32 vote. It will now head to the Senate, where very significant opposition is expected. Key developments:

          1. DIRECT ACCESS: A senior senator has introduced an amendment that would delay direct access provisions by 18 months. If this amendment survives committee, it fundamentally changes our go-to-market timeline for the California expansion. Our legal team is reviewing the specific language.

          2. RATE STRUCTURE: The bill as passed includes a dedicated rate component that would apply to businesses above 500 kW. This is narrower than the original 100 kW threshold, which is actually favorable for our target market segment.

          3. TIMELINE: Senate committee hearings are expected to begin next Tuesday. Floor vote is unlikely before the end of the month. Governor's office has signaled support but with reservations about the rate structure.

          RECOMMENDED ACTIONS:
          • Legal should prepare a memo on the direct access implications by Friday
          • Government affairs should schedule meetings with the three swing-vote senators
          • We should hold off on the San Francisco office lease signing until the Senate vote is clear

          Kristin Walsh
          Government Affairs Research
        BODY
      }
    ]
  },

  # 14. Conference speaking invitation
  {
    subject: "Invitation to Speak at Power 2000 Conference",
    from: "rachel.lloyd@events-intl.com",
    to: "vince@acme.com",
    messages: [
      {
        from: "rachel.lloyd@events-intl.com",
        body: <<~BODY
          Hi Vince,

          It is my great pleasure to invite you to speak at Power 2000, which will be held in Houston on May 9-10.

          Would you be interested in chairing one of the streams on Day 2 of the conference? Or making a full presentation on one of the days? Please let me know which topics interest you. Obviously, some of the slots are no longer available, but I would like to give you a choice as much as possible.

          Available streams include:
          • "Risk Management in Deregulated Markets" (Day 2, Morning)
          • "Quantitative Methods for Energy Trading" (Day 2, Afternoon)
          • "Technology Innovation in Operations" (Day 1, Afternoon panel)

          We cover travel and accommodation for all speakers, and there's a speakers' dinner on the evening of May 8th that's always a great networking opportunity.

          Please could you get back to me ASAP on 212-925-1864 ext 151 or by return email. I very much hope you can join us again this year.

          Best regards,
          Rachel Lloyd
          Events International
        BODY
      },
      {
        from: "vince@acme.com",
        body: <<~BODY
          Rachel,

          Thank you for the invitation. I'd be happy to participate again this year.

          I'd prefer the "Quantitative Methods for Energy Trading" stream on Day 2 — I've been working on some new approaches to volatility modeling that I think the audience would find interesting. I can prepare a 30-minute presentation with Q&A.

          Could you send me the logistics details and the list of other confirmed speakers? I'd like to coordinate with anyone else presenting on related topics to minimize overlap.

          Looking forward to it.

          Best,
          Vince
        BODY
      }
    ]
  },

  # 15. Weekend plans — casual
  {
    subject: "Re: Movie This Weekend",
    from: "jana.mills@external.com",
    to: "vince@acme.com",
    status: Conversation::STATUS_ARCHIVED,
    messages: [
      {
        from: "jana.mills@external.com",
        body: <<~BODY
          Vince,

          Let's talk tomorrow and see what time that movie starts and when we should meet, OK? I was thinking the 5:00 or 7:30 showing at the Edwards on Westhampton. The early one might be better since we could grab dinner afterwards at that new Italian place Sarah was telling us about.

          Also, did you ever hear back from the Petersons about next weekend? If they're in, we should book the lake house soon — it fills up fast once the weather gets warm.

          Jana
        BODY
      },
      {
        from: "vince@acme.com",
        body: <<~BODY
          Jana,

          We should have the movie schedule for the weekend tomorrow. Saturday around 5:00 PM would work for me — the early showing plus dinner sounds perfect. I'll make a reservation at the Italian place just in case.

          Haven't heard back from the Petersons yet. I'll text Mark tonight. You're right that we should lock in the lake house soon.

          See you tomorrow,
          Vince
        BODY
      }
    ]
  },

  # 16. Confidential business intelligence
  {
    subject: "Re: Peoples — Confidential Risk Assessment",
    from: "laura.luce@acme.com",
    to: "exec@acme.com",
    tags: ["Urgent", "Legal"],
    assign_to: "louise",
    messages: [
      {
        from: "laura.luce@acme.com",
        body: <<~BODY
          I am sure no one wants to provide another "we're strong and stable" speech, but we have it on an extremely confidential basis that a memo is being drafted by their risk management group — remember the thorn in Bill's side and mine over the last few years — that recommends a ceasing of additional business with us and a review of their remedies under our agreements for "significant changes in financial capacities."

          I have no idea how far Dick or Tom may let this go, but it is bad form, to say the least. We need to get ahead of this before the memo circulates beyond their risk team.

          My recommendation:
          1. Schedule a call with their CFO for early next week — frame it as a routine relationship check-in, not a response to the memo
          2. Have Legal pull our contractual obligations under the master agreement, specifically the MAC clause language
          3. Prepare talking points that emphasize our liquidity position and credit facility headroom

          This should stay within the exec team until we have a strategy. Please do not forward.

          Laura Luce
        BODY
      },
      {
        from: "louise@acme.com",
        body: <<~BODY
          Laura — understood. I'll set up the call with their CFO through back channels. Agree that the framing matters here.

          Jeff — can you pull together the financial talking points? Focus on the Q3 cash flow numbers and the undrawn revolver. We want facts, not spin.

          Vince — any intelligence from your contacts there on who's driving this internally? Knowing whether it's coming from the CRO or the trading desk would change our approach.

          Let's regroup Wednesday morning before any outreach.

          Louise
        BODY
      }
    ]
  },

  # 17. Research team site visit
  {
    subject: "Houston Trip — Tiger Team Research Project RSVPs",
    from: "stinson@acme.com",
    to: "research@acme.com",
    tags: ["Ops", "HR"],
    messages: [
      {
        from: "stinson@acme.com",
        body: <<~BODY
          Hello everyone!

          Regarding the Tiger Team research project Houston trip, these are the RSVPs I've received:

          CONFIRMED:
          • Jaideep Singh
          • Dennis Feerick
          • Kim Whitsel (and Team 1 — 3 people)
          • Ram Vittal
          • Heather Thorne
          • Vincent Chen
          • Jack Rejtman
          • Deepa Mallik
          • Josh Leventhal
          • Omar Bassal
          • Stephen Lessar

          Note: Heather and Jack have requested to stay in Houston until Sunday. Expenses beyond Friday at the office will be individually borne.

          Donna, would you please review this list, add the individual names from Team 1, add any additional faculty, then make travel arrangements for everyone? The Doubletree near the Galleria worked well last time, but I'm open to alternatives if there's better availability.

          The agenda for the two-day visit will include:
          • Day 1: Trading floor walkthrough, system architecture deep-dive, lunch with the quant team
          • Day 2: Workshops on model validation, portfolio optimization, and a wrap-up planning session

          Please confirm your attendance by end of day Friday so we can finalize logistics.

          Stinson
        BODY
      }
    ]
  },

  # 18. Customer support — Login issues
  {
    subject: "Support Request — Cannot Access Dashboard After Password Reset",
    from: "customer@globalwidgets.com",
    to: "support@acme.com",
    tags: ["Support"],
    assign_to: "maria",
    messages: [
      {
        from: "customer@globalwidgets.com",
        body: <<~BODY
          Hi Support Team,

          I reset my password yesterday using the "Forgot Password" link and received the confirmation email. However, when I try to log in with my new password, I get the following error:

          "Your account has been temporarily locked due to multiple failed login attempts. Please contact your administrator."

          I've only tried logging in twice with the new password, so I'm not sure why it thinks there have been multiple failed attempts. My username is robert.chen@globalwidgets.com.

          This is blocking me from accessing the analytics dashboard, and we have a board meeting on Thursday where I need to present the Q3 data. Any help getting this resolved quickly would be greatly appreciated.

          Robert Chen
          VP of Analytics, Global Widgets Inc.
          (415) 555-0142
        BODY
      },
      {
        from: "maria@acme.com",
        body: <<~BODY
          Hi Robert,

          I've looked into your account and found the issue. When you reset your password, the system also processed three login attempts from an older browser session that was still cached on your machine. Those failed attempts (because they used the old password) triggered the lockout.

          I've cleared the lockout flag on your account and you should be able to log in now with the new password you set yesterday.

          A couple of recommendations to prevent this in the future:
          1. Close all browser tabs with our app open before resetting your password
          2. Clear your browser's saved passwords for our domain after a reset
          3. If you use a password manager, update the stored credentials right away

          Please let me know if you're able to get in. If you're still blocked, I can set up a screen share to walk through it together.

          Best regards,
          Maria Lopez
          Acme Support Team
        BODY
      },
      {
        from: "customer@globalwidgets.com",
        body: <<~BODY
          Maria,

          That worked perfectly — I'm back in now. Thank you for the quick response and the clear explanation. The cached browser session theory makes total sense; I had a tab open on my laptop at home.

          Really appreciate the fast turnaround. You've saved my board presentation prep!

          Best,
          Robert
        BODY
      }
    ]
  },

  # 19. Partnership / integration proposal
  {
    subject: "Partnership Proposal — API Integration Opportunity",
    from: "alex.rivera@partner.io",
    to: "info@acme.com",
    messages: [
      {
        from: "alex.rivera@partner.io",
        body: <<~BODY
          Hi team,

          I'd love to explore a potential integration between our products. We've been building a document management platform that several of your existing customers are already using, and we keep hearing requests for a native integration with Acme's email workflows.

          The use case is straightforward: when an email arrives with attachments, users want the option to automatically file those documents into their Partner.io workspace with metadata pulled from the email headers (sender, date, subject as the document title).

          We have a well-documented REST API and a webhook system that could make this relatively lightweight to build. On our end, we'd handle the document ingestion and indexing. On yours, we'd need:

          1. A webhook or callback when new messages arrive with attachments
          2. Access to the attachment binary and basic email metadata
          3. An OAuth flow so users can authorize the connection from their Acme settings

          We're a 45-person company based in Portland, currently serving about 2,000 business customers. Happy to share our API docs, security audit results, and customer overlap analysis.

          Would anyone on your team be available for a 30-minute call next week to discuss?

          Best,
          Alex Rivera
          Head of Partnerships, Partner.io
        BODY
      }
    ]
  },

  # 20. Invoice confirmation
  {
    subject: "Invoice #8847 — Payment Confirmation & Receipt",
    from: "billing@stripe.com",
    to: "billing@acme.com",
    tags: ["Billing"],
    status: Conversation::STATUS_ARCHIVED,
    messages: [
      {
        from: "billing@stripe.com",
        body: <<~BODY
          Payment of $2,450.00 USD was successfully processed.

          Invoice Details:
          • Invoice Number: INV-8847
          • Date: November 15, 2024
          • Amount: $2,450.00 USD
          • Payment Method: Visa ending in 4242
          • Description: Acme Corp — Enterprise Plan (Monthly)

          Line Items:
          • Enterprise Plan Base: $1,500.00
          • Additional Users (19 × $50): $950.00

          Your next invoice will be generated on December 15, 2024.

          A PDF copy of this invoice is available in your billing portal. If you need to update your payment method or billing address, you can do so at any time from your account settings.

          — Stripe Billing
        BODY
      }
    ]
  },

  # 21. Moody's credit upgrade
  {
    subject: "Moody's Upgrade — Background and Key Takeaways",
    from: "stinson@acme.com",
    to: "research@acme.com",
    tags: ["Finance", "VIP"],
    messages: [
      {
        from: "stinson@acme.com",
        body: <<~BODY
          To the great and powerful Research Group:

          As you may know, Moody's has recently upgraded our credit rating from Baa2 to Baa1. We had been on watch for an upgrade for a while, and after their initial credit meeting, they still had questions — primarily related to our control of market and credit risk.

          To that end, Jeff and Tim had Rick, Bill, and me meet with eight members of the Moody's team. The questions centered around policy and procedure in the wholesale businesses. We discussed:

          • How we set and monitor trading limits
          • The independence of the risk management function from the trading desks
          • Our stress testing methodology (they were particularly interested in the scenario analysis we ran after the Asian crisis)
          • Counterparty credit assessment and concentration limits

          The Moody's team seemed genuinely impressed with the sophistication of our risk infrastructure. Several of them commented that we were ahead of most comparably-sized firms in our industry.

          This upgrade should save us approximately $3-4M annually in borrowing costs on our revolving credit facility. More importantly, it strengthens our position with counterparties who use credit ratings as a threshold for trading limits.

          Good work by everyone who contributed to getting our risk story in order.

          Stinson
        BODY
      }
    ]
  },

  # 22. Internship inquiry
  {
    subject: "Re: Summer Internship — Interview Scheduling",
    from: "shane.green@lsu.edu",
    to: "vince@acme.com",
    tags: ["HR"],
    messages: [
      {
        from: "shane.green@lsu.edu",
        body: <<~BODY
          Dr. Kaminski,

          I just wanted to touch base and see if I needed to mail a hard copy of my resume or get in touch with anyone else at the company.

          The finance department at LSU will be sending out financial award letters to new PhD students before long, and my interning at Acme this summer would free up some additional department money. The department has been very supportive and would prefer to award money to students who have outside funding, so the timing works well for everyone.

          My research interests align closely with the work your team has been doing on stochastic volatility models. I've been working on extending the Heston model to incorporate regime-switching dynamics, and I think there could be some practical applications for the kind of risk analysis you do.

          I'm flexible on dates — any time between May 15 and August 30 would work. I can also come in for a few days before the internship officially starts if that helps with onboarding.

          Thank you again for considering me.

          Best regards,
          Shane Green
          PhD Candidate, Department of Finance
          Louisiana State University
        BODY
      },
      {
        from: "vince@acme.com",
        body: <<~BODY
          Shane,

          Monday would work for us. My assistant will contact you Wednesday to arrange the interviews.

          We typically structure the internship as a 12-week program with a specific research project. Given your background in regime-switching models, I have a project in mind that involves calibrating our volatility surface to account for structural market shifts. We can discuss the details when you're here.

          You'll interview with me, Stinson Gibner (our research lead), and one of the senior analysts. Plan for about half a day.

          No need for a hard copy of the resume — the electronic version is fine.

          Looking forward to meeting you.

          Vince
        BODY
      }
    ]
  },

  # 23. DNS verification — system notification
  {
    subject: "DNS Verification Complete — All Records Confirmed",
    from: "noreply@inbox2.io",
    to: "admin@acme.com",
    status: Conversation::STATUS_ARCHIVED,
    messages: [
      {
        from: "noreply@inbox2.io",
        body: <<~BODY
          All DNS records for acme.com have been verified successfully.

          Verified Records:
          • MX: mx1.inbox2.io (priority 10) ✓
          • MX: mx2.inbox2.io (priority 20) ✓
          • SPF: v=spf1 include:inbox2.io ~all ✓
          • DKIM: inbox2._domainkey.acme.com ✓
          • DMARC: v=DMARC1; p=quarantine; rua=mailto:dmarc@acme.com ✓

          Your domain is now fully configured to send and receive email through Inbox2. Inbound mail delivery is active and outbound messages will pass SPF, DKIM, and DMARC authentication.

          If you make changes to your DNS records in the future, verification will run automatically within 24 hours. You can also trigger a manual re-check from your domain settings page.

          — Inbox2 System
        BODY
      }
    ]
  },

  # 24. Candidate meritocracy review — HR
  {
    subject: "Additional Candidates for Meritocratic Review",
    from: "shirley@acme.com",
    to: "hr@acme.com",
    tags: ["HR"],
    messages: [
      {
        from: "shirley@acme.com",
        body: <<~BODY
          Robert,

          I was looking through the initial packet of candidates submitted as meritocratic examples of rapid career advancement, and there are a few individuals we might want to reconsider:

          COMMERCIAL TRACK:
          • Jennifer Fraser — Associate to Director in 37 months. Led the European gas desk expansion and consistently exceeded her P&L targets. Strong mentorship record.
          • Heather Kroll — Associate to Director in 42 months. Built the real-time risk analytics platform from scratch. Her team's work reduced overnight risk processing time by 60%.
          • Jeanette Reese — Associate to Director in 49 months. Managed the largest client portfolio in the division.

          NON-COMMERCIAL TRACK:
          • Leslie Foust — Sr. Specialist to Director in 50 months. Transformed the compliance reporting process and saved an estimated $400K/year in external audit fees.

          These are exceptional trajectories and I think they deserve recognition. The common thread is that each of them took on a significant operational challenge that nobody else wanted, and delivered results that were measurable and substantial.

          Can we add them to the presentation for the next talent committee meeting?

          Shirley
        BODY
      }
    ]
  },

  # 25. Settlement calculation — finance ops
  {
    subject: "Pan Energy Exchange Settlement — February Production",
    from: "katherine@acme.com",
    to: "finance@acme.com",
    tags: ["Finance", "Billing"],
    assign_to: "katherine",
    messages: [
      {
        from: "katherine@acme.com",
        body: <<~BODY
          Robert,

          Attached, please find our calculation sheet for February production. Please review it and let me know if you have any questions.

          At this time, it appears that we owe Pan Energy $56,562.68. This amount, however, does not include the re-delivery fuel charges from PG&E that will be passed back to Pan Energy.

          As soon as we receive the information from PG&E, we will bill you accordingly. Based on last month's charges, I'd estimate the fuel adjustment will be in the $4,000-$5,000 range, which would net our payable down to approximately $51,500.

          Please confirm receipt and let me know if the numbers align with your records. I'd like to have this reconciled by the 15th so we can process payment on schedule.

          Thanks,
          Katherine Walker
          (713) 345-8643
        BODY
      }
    ]
  },

  # 26. Draft reply in progress — sits in the Drafts view, not the Inbox
  {
    subject: "Re: Pipeline Capacity Reservation — Q1",
    from: "kent.castleman@acme.com",
    to: "louise@acme.com",
    tags: ["Operations"],
    messages: [
      {
        from: "kent.castleman@acme.com",
        body: <<~BODY
          Louise — can you confirm the reserved capacity figures for Q1 before I take this to the committee? I want to make sure the Henry Hub allocation matches what we agreed in December.
        BODY
      },
      {
        from: "louise@acme.com",
        draft: true,
        body: <<~BODY
          Kent — yes, the Q1 reservation is confirmed at the December numbers. Henry Hub allocation is unchanged. I'll pull the signed schedule and attach it here before you take it to the
        BODY
      }
    ]
  }
]

conversations_data.each_with_index do |conv_data, i|
  seed_conversation(
    org: org,
    data: conv_data,
    # Only every fourth thread keeps its tags — labels are a human act, and an
    # inbox where every row is tagged reads as fake.
    tags: (i % 4).zero? ? (conv_data[:tags] || []) : [],
    members: members,
    all_tags: tags
  )
end

puts "Seeding delivery channel..."
DeliveryChannel.ensure_builtin(org)

puts "Seeding notifications..."
conv1 = Conversation.find_by(subject: "Q4 Board Presentation — Updated Deck")
if conv1
  Notification.find_or_create_by!(user: owner, organization: org, kind: "assignment", title: "Louise assigned you to Q4 Board Presentation") do |n|
    n.conversation = conv1
    n.actor_membership_id = members["louise"][:membership].id
  end
end

conv_risk = Conversation.find_by(subject: "Re: Peoples — Confidential Risk Assessment")
if conv_risk
  Notification.find_or_create_by!(user: owner, organization: org, kind: "mention", title: "Laura mentioned you in Peoples risk discussion") do |n|
    n.conversation = conv_risk
    n.actor_membership_id = members["louise"][:membership].id
  end
end

# ── Multi-domain + per-domain access demo ────────────────────────────────────
# The org owns a SECOND domain (widgets.co); the pool is still shared, but some
# members are scoped to see only one domain's slice. Exercises the per-domain
# access model — the console per-domain cards, the Team-tab domain grants, and
# the inbox visibility filter.
puts "Seeding a second domain + scoped members..."
acme_domain = org.domains.find_by(name: "acme.com")
widgets = Domain.find_or_create_by!(name: "widgets.co") do |d|
  d.organization = org
  d.status = Domain::STATUS_RECEIVING_MAIL
end

# Attribute every existing thread to the primary domain, then a few to widgets.co.
Conversation.where(organization: org, domain_id: nil).update_all(domain_id: acme_domain.id)

widgets_threads = [
  { subject: "widgets.co — order #4821 stuck in fulfillment", from: "buyer@shop.example", to: "support@widgets.co",
    messages: [{ from: "buyer@shop.example", body: "My widgets order hasn't shipped in a week — can you check?" }] },
  { subject: "Wholesale pricing for widgets.co", from: "procurement@bigco.example", to: "sales@widgets.co",
    messages: [{ from: "procurement@bigco.example", body: "We'd like a volume quote for 5,000 units." }] },
  { subject: "widgets.co returns policy question", from: "shopper@mail.example", to: "help@widgets.co",
    messages: [{ from: "shopper@mail.example", body: "Is the 30-day return window business days or calendar?" }] }
]
widgets_threads.each { |data| seed_conversation(org: org, data: data, tags: [], members: members, all_tags: tags) }
Conversation.where(organization: org, subject: widgets_threads.map { |d| d[:subject] }).update_all(domain_id: widgets.id)

# Scope two members to a single domain each; owner + admins stay on all domains.
# (find_or_create is idempotent, so re-seeding just re-applies the grants.)
def scope_member(membership, domain)
  membership.domains = [domain]           # grant first (persists the join)…
  membership.update!(all_domains: false)  # …then flip the flag with the grant present
end
scope_member(members["sarah"][:membership], widgets)     # Sarah → widgets.co only
scope_member(members["alex"][:membership], acme_domain)  # Alex  → acme.com only

puts "Done! Seeded #{User.count} users, #{Organization.count} orgs, #{Domain.count} domains, #{Conversation.count} conversations, #{Message.count} messages"
puts "Login: username=demo password=password123  (scoped demo: sarah→widgets.co, alex→acme.com)"
