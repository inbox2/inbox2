import Legal, { Fill } from "../components/Legal/Legal.jsx";

export function meta() {
  return [
    { title: "Terms of service | inbox2" },
    {
      name: "description",
      content:
        "The agreement between you and Sadiq Beheer B.V. for using inbox2: the apps, the hosted MX service, and the source code.",
    },
  ];
}

const SECTIONS = [
  { id: "parties", label: "Who this is between" },
  { id: "service", label: "What inbox2 is" },
  { id: "account", label: "Your account" },
  { id: "use", label: "What you may not do" },
  { id: "content", label: "Your mail is yours" },
  { id: "plans", label: "Plans and payment" },
  { id: "availability", label: "Availability" },
  { id: "ending", label: "Ending it" },
  { id: "software", label: "The apps and the source" },
  { id: "liability", label: "Liability" },
  { id: "law", label: "Law and courts" },
  { id: "changes", label: "Changes" },
];

export default function Terms() {
  return (
    <Legal
      title="Terms of service"
      updated="9 November 2026"
      sections={SECTIONS}
      lede="You own your mail, we run a service around it, and if we ever stop being worth it you can take everything and go. The rest of this page is that idea written carefully enough to hold up."
    >
      <h2 id="parties">Who this is between</h2>
      <p>
        These terms are an agreement between you, or the organisation you sign up on behalf
        of, and <strong>Sadiq Beheer B.V.</strong>, trading as inbox2, registered in the
        Netherlands under KVK number <Fill>KVK number</Fill> at{" "}
        <Fill>registered address</Fill>. Creating an account, connecting a mailbox or
        pointing a domain at us means you accept them. If you are signing up for a company,
        you are confirming you are allowed to bind it.
      </p>
      <p>
        You need to be 16 or older to hold an inbox2 account.
      </p>

      <h2 id="service">What inbox2 is</h2>
      <p>
        Two things, and they are priced differently. The <strong>apps</strong> for macOS,
        Windows, Linux, iOS, Android, the browser and the terminal are free, and they work
        with mail accounts you already have by talking to those providers from your own
        device. <strong>inbox2 MX</strong> is a hosted mail service: you point a
        domain&rsquo;s MX records at us and we receive, store and send that domain&rsquo;s
        mail, with shared views and routing rules over it. Paid plans also include{" "}
        <strong>Disk</strong>, file storage for you and your team.
      </p>
      <p>
        What each plan includes and costs is on the{" "}
        <a href="/mx#pricing">pricing section</a>, and that page is part of these terms.
      </p>

      <h2 id="account">Your account</h2>
      <p>
        Keep your credentials to yourself and tell us at{" "}
        <a href="mailto:security@inbox2.com">security@inbox2.com</a> if you think someone
        else has them. You are responsible for what happens under your account and for what
        the people you invite into your organisation do with it. A shared inbox works by
        letting an organisation owner see and administer the domain mail their members
        handle, so tell your team.
      </p>

      <h2 id="use">What you may not do</h2>
      <ul>
        <li>Send spam, phishing, malware, or anything else that would get a mail server blocklisted.</li>
        <li>Use the service to break the law, harass anyone, or infringe someone else&rsquo;s rights.</li>
        <li>Try to reach another customer&rsquo;s data, or probe, scan or load-test our production systems without written permission. Responsible security research reported to <a href="mailto:security@inbox2.com">security@inbox2.com</a> is welcome and we will not come after you for it.</li>
        <li>Resell the hosted service as your own, or run it in a way designed to dodge your plan&rsquo;s limits.</li>
      </ul>
      <p>
        We will suspend an account that is actively harming the mail deliverability of every
        other customer on the platform, and we will tell you why.
      </p>

      <h2 id="content">Your mail is yours</h2>
      <p>
        You keep every right you have in your mail, your attachments, your contacts and
        anything else you put into inbox2. You grant us the narrow permission we need to run
        the service: to receive, store, transmit, index for search, back up and display that
        content to you and to the people in your organisation you have given access to. That
        permission ends when the content does.
      </p>
      <p>
        We do not read your mail, mine it, train models on it, or sell it. Server-side AI
        triage on paid plans sends message text to a classification provider only when your
        organisation switches it on, and the{" "}
        <a href="/privacy">privacy policy</a> covers what happens to it there.
      </p>
      <p>
        The same holds for the files you keep on Disk. You decide who can open them. A
        public link opens a file to anyone who has the link, so what you share through one
        is your responsibility. The <a href="/privacy#disk">privacy policy</a> says where
        the files are stored and how long deleted ones are kept.
      </p>

      <h2 id="plans">Plans and payment</h2>
      <p>
        Paid plans are billed in advance per billing period, per organisation, through Stripe.
        Prices exclude VAT, which is added where it applies. We can change prices with 30
        days&rsquo; notice by email, and the new price takes effect at your next renewal, so
        you always have a period to leave first. Payments already made are non-refundable
        except where Dutch consumer law says otherwise.
      </p>
      <p>
        If a payment fails we will retry and email you. After <Fill>dunning period</Fill>{" "}
        we may downgrade the organisation to the free tier or suspend it.
      </p>

      <h2 id="availability">Availability</h2>
      <p>
        We work hard to keep the service up and we do not offer a contractual uptime
        guarantee today. There is no SLA, no credit scheme and no promised response time,
        and pretending otherwise in a document you might one day need to rely on would be
        dishonest. We do maintenance when it is needed and announce anything disruptive in
        advance where we can.
      </p>
      <p>
        The service is provided as it is. We do not warrant that it will be uninterrupted,
        error free, or that it will suit a particular purpose of yours.
      </p>

      <h2 id="ending">Ending it</h2>
      <p>
        You can close your account whenever you like, from the console. Closing it stops the
        next renewal and, once you confirm, deletes your data on the schedule in the{" "}
        <a href="/privacy#retention">privacy policy</a>. Export what you want first.
      </p>
      <p>
        We can end this agreement with 30 days&rsquo; notice, or immediately if you breach
        the section above on what you may not do, or if you fail to pay. If we shut the
        service down entirely, we will give you at least 90 days to get your mail out.
      </p>

      <h2 id="software">The apps and the source</h2>
      <p>
        The inbox2 apps (web, desktop, iOS, Android and the command line) are open source
        under the Apache License 2.0. The server, the mail transport and the deployment
        code are under the Functional Source License 1.1 (FSL-1.1-ALv2): you can read, run,
        change and self-host them, but you can&rsquo;t offer them as a competing hosted
        service. Each release becomes Apache 2.0 two years after it ships. These terms
        govern the hosted service we operate, and the licences govern the code. Where they
        disagree about the code, the licence wins.
        {/* Counsel review pending (2026-09-25): licence wording mirrors api/LICENSE.md. */}
      </p>
      <p>
        The inbox2 name, the wordmark and the logo are not covered by those licences and stay
        ours. Run your own copy as much as you like, and please call it something else.
      </p>
      <p>
        The apps check for updates and install them. You can turn that off in settings.
      </p>

      <h2 id="liability">Liability</h2>
      <p>
        Nothing here limits our liability for death or personal injury, for fraud, or for
        anything else the law says cannot be limited. Subject to that, our total liability
        to you for any claim is capped at what you paid us in the 12 months before it arose,
        and we are not liable for indirect or consequential loss, lost profits, lost business
        or lost data beyond that cap.
      </p>
      <p>
        Email is a store-and-forward system built on other people&rsquo;s servers, and
        messages are sometimes delayed, rejected or filtered by a receiving provider for
        reasons outside anyone&rsquo;s control. We are not liable for those.
      </p>

      <h2 id="law">Law and courts</h2>
      <p>
        Dutch law applies. Disputes go to the competent court in{" "}
        <Fill>court district</Fill>, the Netherlands. If you are a consumer, you keep the
        protections and the local courts your own country&rsquo;s law gives you.
      </p>

      <h2 id="changes">Changes</h2>
      <p>
        We update these terms as the product changes and the date at the top moves with
        them. Material changes are emailed to account holders at least 30 days before they
        take effect, and carrying on using the service after that means you accept them. If
        you would rather not, close the account before the date and we will refund the
        unused part of your current period.
      </p>
      <p>
        Questions about any of this go to{" "}
        <a href="mailto:legal@inbox2.com">legal@inbox2.com</a>.
      </p>
    </Legal>
  );
}
