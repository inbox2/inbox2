// The demo cast's mail: one subject per thread, with the body that belongs to it.
//
// Paired on purpose — a screenshot shows the subject and the body together, and
// "Invoice #4821 is ready" over three paragraphs about a pilot timeline reads as
// obviously generated. demoData.js seeds both from the same hash, so a thread's
// subject, preview and body always agree.
//
// Written in the register of the Enron corpus in api/tmp/datasets (which is what
// `rake datasets:load[enron]` unpacks): two or three short paragraphs, opening
// mid-thought, one concrete number or date, a hedge, and an ask at the end. The
// corpus text itself is NOT used — it carries real names, real HR decisions about
// named employees, personal family mail and the odd slur, none of which belongs
// in a product screenshot. This is the shape of that mail, not its content.
//
// No real people or companies: the senders come from the generated cast in
// demoData.js, so a body must never name anyone, or the name on the row and the
// name in the text would disagree.

const THREADS = [
  {
    subject: 'Q3 pipeline review — action needed',
    body: `I went through the deck on the train this morning and the numbers line up with what finance sent over last week, give or take the two renewals we moved into October.

The part I still can't place is slide 7. It shows 14 open opportunities in the enterprise segment, but the export I pulled on Friday had 11. Could you check whether the three demos from the trade fair were counted twice?

I'd like to lock the forecast before the board call on the 12th, so anything you can confirm before Thursday helps.`,
  },
  {
    subject: 'Contract redlines back from legal',
    body: `Their counsel came back with comments on clause 8 and clause 14. Clause 8 is fine — they want the notice period in writing rather than by reference, which costs us nothing.

Clause 14 is the one to look at. As drafted, liability is capped at twelve months of fees; they've asked for six. I'd accept six if we can keep the carve-out for data loss, and I'd rather not trade both away in the same round.

Can you live with that? If so I'll send it back today and we should have signature before the end of the month.`,
  },
  {
    subject: 'Invoice #4821 is ready',
    body: `The October invoice is attached. Total is € 12.480,00 including the two extra seats added on the 9th, payable within 30 days.

One change from last month: the usage line is now split per department, since your finance team asked to see marketing separately. Nothing else moved.

If the split still isn't what they need, tell me how you want it cut and I'll reissue rather than have you rebuild it in a spreadsheet.`,
  },
  {
    subject: 'Onboarding plan for the Rotterdam team',
    body: `Rotterdam comes over on the 14th — 23 people, all in the same building, so we can do it in one session rather than the three we needed for Utrecht.

I've asked for two hours in the morning and a drop-in desk in the afternoon. In my experience the drop-in is what actually gets people moved; the session mostly sets expectations.

The only open item is the shared mailbox. It has about 9.000 messages in it and nobody is quite sure what still needs answering. Could someone on your side sort out what's live before we import it?`,
  },
  {
    subject: 'Renewal quote — 24 months',
    body: `Attached is the quote for the 24-month renewal. It holds this year's unit price, which is a real concession given we moved list in April, and it includes the sandbox environment you've been using informally since the spring.

I've left the seat count at 140. You mentioned two teams joining in Q1 — we can add them mid-term at the same rate rather than rewriting the agreement.

The quote is good until the end of the month. After that I'd have to requote at list, which neither of us wants to explain.`,
  },
  {
    subject: 'Security questionnaire (SOC 2 section)',
    body: `I've filled in everything up to section 6. Sections 1 through 5 are straightforward — the answers haven't changed since the last review, and I've attached the current report rather than retyping it.

Section 6 asks about subprocessors, and there I need help. We added a new one for transactional mail in July and I'd rather their compliance team read it from us now than find it in an audit later.

Who owns the subprocessor list on your side these days? I'll send them the two paragraphs I have and they can correct me.`,
  },
  {
    subject: 'Press embargo lifts Thursday',
    body: `The embargo lifts Thursday at 09:00 CET. Two trade titles have the release, and one has asked for a fifteen-minute call with someone technical before they publish.

I'd suggest we don't push the integration story this round. It's the least finished part and the questions will all land there.

If you can give me a name for the call by tomorrow lunchtime, I'll set it up. Otherwise I'll take it myself and keep it high level.`,
  },
  {
    subject: 'Design review: the new billing screens',
    body: `Sat with the two flows this afternoon. The invoice list is a clear improvement — the per-department split is legible now and the empty state finally says something useful.

Where I got stuck is the seat-change dialog. It asks for the effective date before it asks what's changing, which is backwards from how anyone actually thinks about it, and the preview underneath only updates after both are set.

Worth a rework before we put it in front of the pilot accounts? It's the one screen finance people will touch every month.`,
  },
  {
    subject: 'Weekly numbers — week 38',
    body: `Numbers for the week are in the sheet. Two things stand out. Renewals are ahead of plan — eleven closed against a forecast of eight — and support volume dropped by about a fifth after the release on the 9th.

The support drop is probably the import fix rather than anything seasonal; the tickets that disappeared are exactly the ones that used to say "my mail didn't come across".

I'd hold off on reading much into new business this week. Two of the four signatures slipped into next week for holiday reasons, nothing more.`,
  },
  {
    subject: 'Shipment INT-99041 cleared customs',
    body: `INT-99041 cleared this morning and is on the road — delivery window is Thursday between 10:00 and 14:00, and someone needs to be there to sign.

The paperwork had the old delivery address on it, which is what held it up on Monday. I've corrected it in the system, but anything already in transit still carries the old one, so expect one more of these.

Could you confirm someone will be at the dock on Thursday? If not I'd rather reschedule now than have it sit in a depot over the weekend.`,
  },
  {
    subject: "Can we move Tuesday's call to 15:00?",
    body: `Tuesday at 11:00 has become difficult — the quarterly review ran over and it's now scheduled straight through the morning.

Could we move to 15:00 the same day? I'd rather not push it to Wednesday, because then we're deciding the campaign budget after the spend has already started.

If 15:00 doesn't suit, Thursday morning is wide open on my side and I'll work around you.`,
  },
  {
    subject: 'DPA countersigned — copy attached',
    body: `The DPA came back countersigned this morning. Copy attached for your records; I've also put it in the shared folder next to the master agreement.

Two things changed between the draft you reviewed and the executed version, both at their request: the audit notice went from 14 days to 30, and the subprocessor list is now referenced by URL rather than pasted into the annex.

Neither worried our side, but you should know before anyone compares the two documents and wonders.`,
  },
  {
    subject: 'Roadmap: what lands before the freeze',
    body: `Going through what's realistically done before the freeze on the 20th. The import rewrite and the new billing screens are both close enough that I'd commit to them.

Search is the one I'd cut. It works, but it's slow on the larger accounts — about four seconds on the biggest mailbox we have — and shipping it that way just moves the complaint from "we don't have search" to "your search is broken".

That leaves the quarter one item short of what we told the board. I'd rather explain that now than in January.`,
  },
  {
    subject: 'Support escalation — ticket 7741',
    body: `Ticket 7741 has been open nine days and the customer has now asked twice for someone to call them. Whatever the technical answer turns out to be, that part is on us.

As far as I can tell the mail is being delivered but filed into a folder nobody watches, which is why they think it's missing. That would explain why the logs look clean.

I've offered a call tomorrow at 11:00. Could someone who actually understands the routing rules join? I can hold the conversation but I can't answer the follow-up.`,
  },
  {
    subject: 'Offsite logistics and the hotel block',
    body: `The hotel is holding 18 rooms for the nights of the 3rd and 4th, released on the 20th if we haven't confirmed numbers.

Right now I have 14 confirmed, two maybes and two who haven't answered. If the maybes turn into yesses we're fine; if the two silent ones also come, I need to ask for more rooms this week rather than next.

Could you nudge the people on your side? One line back, yes or no, is all I need.`,
  },
  {
    subject: 'Budget approval for the Q4 campaign',
    body: `The Q4 plan comes to € 48.000, which is about 15% over what we spent in Q3. The increase is almost entirely the trade fair — the stand alone is € 11.000 before anything is printed.

My honest view is that the fair earns its place only if we come away with meetings booked rather than badges scanned. Last year we scanned 300 badges and had four real conversations.

If you'd rather hold the budget flat, I'd drop the fair and put the money into the two webinars, which we can measure properly.`,
  },
  {
    subject: 'API rate limits on the sandbox key',
    body: `Your sandbox key is raised to 600 requests a minute for the duration of the integration, so the import script shouldn't hit the wall it hit on Friday.

One thing to watch: the limit is per key, not per environment, so if the test runner and your local machine both use the key you'll share that budget between them. Easiest fix is a second key for CI.

Let me know if 600 is enough once you've run the full import. We can go higher for a window if you tell me when.`,
  },
  {
    subject: 'Notes from the board prep session',
    body: `Short version of this morning: the numbers are fine, the story around them isn't finished yet.

They'll ask why net revenue retention dipped two points. The answer is the two accounts that downsized in June, both for reasons that had nothing to do with the product, and it's worth saying that plainly rather than letting it sit in a footnote.

Could you pull the cohort chart back to eight quarters? At four it looks like a trend. At eight it obviously isn't.`,
  },
];

// Lore's buckets (lib/lore.js) — threads written for one triage label each, so a
// demo of the Today view reads true: the "To pay" row is an invoice, its title
// says what to do, its amount is on it. demoData.js picks a labelled row's
// stand-in from the threads carrying its label. `title` stands in for the
// AI-written to-do title; amounts are cents.
export const LORE_THREADS = [
  {
    label: 'payment_due', title: 'Pay the Helixpay October invoice', amount_cents: 1248000, currency: 'EUR',
    subject: 'Invoice HX-20931 for October',
    body: `Please find the October invoice attached: 24 seats plus the analytics add-on, € 12.480,00 in total.

Payment is due within 14 days. If your purchase order number has changed since September, reply with the new one and we'll reissue the invoice with it.`,
  },
  {
    label: 'payment_due', title: 'Pay the Atlas Freight customs fee', amount_cents: 38600, currency: 'EUR',
    subject: 'Reminder: customs clearance fee for shipment AF-7712',
    body: `This is a reminder that the clearance fee for shipment AF-7712 is still open: € 386,00, due last Friday.

The pallets are held at the warehouse until it's paid. If it's already on its way, you can ignore this message.`,
  },
  {
    label: 'payment_due', title: 'Renew the Stratos domain plan', amount_cents: 14900, currency: 'EUR',
    subject: 'Your Stratos plan renews on 1 November',
    body: `Your Business plan renews on 1 November for € 149,00 per year. The card on file expired in September, so the renewal will fail unless you update it.

Update your payment method before the 31st to keep your domains and mailboxes running.`,
  },
  {
    label: 'needs_answer', title: 'Reply to Northwind on the pilot scope',
    subject: 'Pilot scope — can we start with two teams?',
    body: `We've talked it over internally and we'd like to start the pilot with two teams instead of the whole floor: finance and customer success, about 30 people.

Would that still work on your side for the pricing we discussed? If yes, I can get the order form signed this week.`,
  },
  {
    label: 'needs_answer', title: 'Answer Brightfold about the API limits',
    subject: 'Question about rate limits before we go live',
    body: `Quick one before our launch on Monday: is the 600 requests per minute limit per key or per account?

We're planning to run three integrations in parallel and I want to be sure we won't hit it during the import.`,
  },
  {
    label: 'action_required', title: 'Sign the Veldhuis Legal engagement letter',
    subject: 'Engagement letter ready for signature',
    body: `The engagement letter for the trademark filing is ready. It's in the signing portal now; it takes about two minutes.

We'll file in the Benelux and EU registers as soon as it's signed, so the priority date isn't lost.`,
  },
  {
    label: 'needs_approval', title: 'Approve the Q4 marketing budget',
    subject: 'Q4 budget request — needs your approval',
    body: `Attached is the Q4 request for the events and paid social lines: € 18.000 in total, € 2.500 below Q3.

The conference deposit is due on the 15th, so an approval this week would let us lock the booth.`,
  },
  {
    label: 'scheduling', title: 'Pick a time for the Orbit Labs roadmap review',
    subject: 'Roadmap review — Thursday or Friday?',
    body: `We'd like to walk you through the H1 roadmap before it's final. It takes about 45 minutes.

Would Thursday at 14:00 or Friday at 10:30 work? Happy to send an invite for whichever suits.`,
  },
  {
    label: 'scheduling', title: 'Confirm the Kestrel Data onboarding call',
    subject: 'Invitation: Kestrel onboarding kick-off',
    body: `You're invited to the onboarding kick-off on Tuesday at 11:00. We'll set up the workspace together and import the first data source.

Please accept or propose another time.`,
  },
  {
    label: 'to_review', title: 'Review the September usage report',
    subject: 'Your September usage report',
    body: `Your September report is ready: 1.2M events processed, up 8% on August, with two days near the plan limit.

The full breakdown per workspace is in the dashboard.`,
  },
  {
    label: 'to_review', title: 'Look over the Lumenworks security review',
    subject: 'Security questionnaire — our answers',
    body: `As promised, our completed security questionnaire is attached, together with the latest penetration test summary.

Nothing needs signing — it's for your records and your vendor review.`,
  },
  {
    label: 'read_later', title: 'Read: what we learned shipping offline sync',
    subject: 'What we learned shipping offline sync',
    body: `This month's essay is about the hardest feature we've built: making the app work with no connection at all, and what it taught us about conflicts.

Three lessons, one diagram, and the mistake we'd avoid next time.`,
  },
  {
    label: 'read_later', title: 'Read the Nordkap product newsletter',
    subject: 'Nordkap Monthly: five things new in October',
    body: `Five things shipped this month, from scheduled exports to a faster search.

Plus: a customer story about cutting month-end close from nine days to four.`,
  },
  {
    label: 'waiting_reply', title: 'Waiting on Atlas Freight for the delivery date',
    subject: 'Re: Delivery window for the November order',
    body: `Thanks — could you confirm the delivery window for the November order once the carrier has it?

We need it to plan the warehouse shift.`,
  },
  {
    label: 'fyi', subject: 'Office closed on the 1st',
    body: `A quick note that the office is closed on the 1st for the public holiday. Support stays available by chat.`,
  },
  {
    label: 'fyi', subject: 'Minutes: partner sync, 14 October',
    body: `Minutes from today's partner sync are attached. No actions for you this time — the next sync is in four weeks.`,
  },
  {
    label: 'receipt', subject: 'Your receipt from Stratos',
    body: `Thanks for your payment of € 49,00. This receipt is for your records; nothing else is needed.`,
  },
  {
    label: 'notification', subject: 'Your sign-in code',
    body: `Your sign-in code is 482910. It expires in 10 minutes. If you didn't try to sign in, you can ignore this email.`,
  },
];

export default THREADS;
