import Legal, { Fill } from "../components/Legal/Legal.jsx";
import styles from "../components/Legal/Legal.module.css";

export function meta() {
  return [
    { title: "Privacy policy | inbox2" },
    {
      name: "description",
      content:
        "Where your mail actually lives, what we can read, what we cannot, and who else touches it.",
    },
  ];
}

const SECTIONS = [
  { id: "who", label: "Who we are" },
  { id: "modes", label: "Where your mail lives" },
  { id: "disk", label: "Files on Disk" },
  { id: "google", label: "Google account data" },
  { id: "microsoft", label: "Microsoft account data" },
  { id: "site", label: "This website" },
  { id: "cookies", label: "Cookies" },
  { id: "grounds", label: "Why we may hold it" },
  { id: "sharing", label: "Who else touches it" },
  { id: "retention", label: "How long we keep it" },
  { id: "transfers", label: "Where it is processed" },
  { id: "rights", label: "Your rights" },
  { id: "security", label: "How it is protected" },
  { id: "changes", label: "Changes" },
  { id: "contact", label: "Contact" },
];

export default function Privacy() {
  return (
    <Legal
      title="Privacy policy"
      updated="9 November 2026"
      sections={SECTIONS}
      lede="Most privacy policies are written to make a company look harmless. This one is written to tell you where your mail is, because for most of what inbox2 does the answer is that it sits on your own machine and we cannot read it."
    >
      <h2 id="who">Who we are</h2>
      <p>
        inbox2 is a trade name of <strong>Sadiq Beheer B.V.</strong>, a company registered
        in the Netherlands under KVK number <Fill>KVK number</Fill>, at{" "}
        <Fill>registered address</Fill>. We are the data controller for everything
        described on this page, and you can reach us at{" "}
        <a href="mailto:privacy@inbox2.com">privacy@inbox2.com</a>.
      </p>
      <p>
        We have not appointed a Data Protection Officer. We are not required to, given our
        size and what we process, and if that changes we will name one here.
      </p>

      <h2 id="modes">Where your mail lives</h2>
      <p>
        inbox2 runs in two ways, and they give completely different answers to the question
        of who holds your mail. Read whichever one applies to you.
      </p>

      <h3>Accounts you connect yourself</h3>
      <p>
        Gmail, Outlook, Office 365, any IMAP server: the app on your device talks to that
        provider directly. Your messages, attachments, calendar events and contacts sync
        into a database file on your own disk, on your own machine. They never reach our
        servers. We have no copy to read, to lose, or to hand to anyone who asks.
      </p>
      <p>
        There is one place our server appears in that path. Realtime delivery for Gmail and
        Microsoft works by the provider notifying us that something changed in your
        mailbox, and we then wake your device. That notification carries your email address
        and a change counter. It carries no mail. Token exchange and refresh also pass
        through our server, because the provider requires a client secret we cannot ship
        inside an app that anyone can decompile. We use those tokens to complete the
        exchange and hand them back to your device. We do not store them and we do not use
        them to read your mailbox.
      </p>

      <h3>Domains hosted on inbox2 MX</h3>
      <p>
        If you point your domain&rsquo;s MX records at us, we are running your mail server.
        Messages, attachments, calendars, contacts and the routing rules for that domain
        live in our database, because a mail server that cannot see mail cannot deliver it.
        On paid plans a domain can be sealed with client-side encryption, after which the
        content we hold is ciphertext that our own staff and our own database cannot open.
        Sealing is per domain and it is off by default.
      </p>
      <p>
        Server-side AI triage on paid plans sends message text to a classification provider,
        OpenAI by default, to sort mail into Spaces. That feature is off unless your
        organisation turns it on, and with it off no classification vendor is in the path.
      </p>

      <h2 id="disk">Files on Disk</h2>
      <p>
        Disk is the file storage that comes with paid plans. The files, folders and pages
        you put on Disk are stored on our servers, so that you and your team can reach them
        from every device.
      </p>
      <p>
        The files are kept in a Cloudflare R2 bucket in the European Union. Our database
        holds their names, folders, sizes, versions and sharing settings. It also holds a
        log of activity: uploads, moves, deletions, shares and each time a public link is
        opened.
      </p>
      <p>
        Previews are drawn in your browser. Our server reads an unsealed image, PDF or
        video once to make its thumbnail.
      </p>
      <p>
        A sealed folder is encrypted in your browser before anything is uploaded. We hold
        its files, their names and its pages as ciphertext that we cannot open. Sealing is
        per folder and it is off by default.
      </p>
      <p>
        Your own disk belongs to you. The administrators of your organisation cannot open
        it, and it is left out of their export. A shared disk belongs to the team, and the
        team&rsquo;s administrators manage it.
      </p>
      <p>
        A public link opens a file to anyone who has the link. You can set a password and
        an expiry date on it, and you can revoke it at any time.
      </p>
      <p>
        An import from Google Drive, Microsoft 365 or Dropbox copies the files you choose
        into Disk. It uses access that you or your administrator grants for that import.
      </p>

      <h2 id="google">Google account data</h2>
      <p>
        When you connect a Google account, inbox2 asks for these scopes and uses them for
        these things only:
      </p>
      <div className={styles.tableWrap}>
        <table>
          <thead>
            <tr><th>Scope</th><th>What it is for</th></tr>
          </thead>
          <tbody>
            <tr>
              <td><code>gmail.modify</code></td>
              <td>
                Read your mail into the app, send what you write, and write back the
                actions you take: read and unread, star, archive, label, move, trash.
              </td>
            </tr>
            <tr>
              <td><code>calendar</code></td>
              <td>Show your calendar, create and edit events, answer invitations, and read free/busy for the scheduling assistant.</td>
            </tr>
            <tr>
              <td><code>contacts.readonly</code></td>
              <td>Complete addresses as you type and put a name and face against a sender.</td>
            </tr>
            <tr>
              <td><code>email, profile</code></td>
              <td>Know which account you just connected and label it in the app.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        <strong>
          inbox2&rsquo;s use of information received from Google APIs adheres to the{" "}
          <a href="https://developers.google.com/terms/api-services-user-data-policy" target="_blank" rel="noopener">
            Google API Services User Data Policy
          </a>
          , including the Limited Use requirements.
        </strong>{" "}
        We do not transfer your Google data to anyone, we do not use it for advertising, we
        do not sell it, and no human at inbox2 reads it. On-device AI features run models on
        your own hardware, so mail processed by them stays on the device.
      </p>
      <p>
        You can disconnect the account at any time in the app, which deletes the local copy
        and the stored token, and you can revoke our access outright at{" "}
        <a href="https://myaccount.google.com/permissions" target="_blank" rel="noopener">
          myaccount.google.com/permissions
        </a>.
      </p>

      <h2 id="microsoft">Microsoft account data</h2>
      <p>
        A connected Microsoft or Office 365 account works the same way, through the Graph
        API, with the scopes <code>Mail.ReadWrite</code>, <code>Mail.Send</code>,{" "}
        <code>Calendars.ReadWrite</code>, <code>Contacts.Read</code> and{" "}
        <code>User.Read</code>. Same rule: the mail syncs to your device, we hold no copy,
        and we use the access for nothing except running the app in front of you. Revoke it
        at{" "}
        <a href="https://myaccount.microsoft.com/privacy" target="_blank" rel="noopener">
          myaccount.microsoft.com
        </a>.
      </p>

      <h2 id="site">This website</h2>
      <p>
        inbox2.com is a set of static pages on Cloudflare Pages. It has no forms and no
        login. Cloudflare terminates TLS and keeps short-lived request logs, including IP
        addresses, to serve the page and to stop attacks. Beyond that the only thing
        collecting anything is analytics, and only if you agreed to it.
      </p>
      <p>
        The waitlist and signup forms live on mail.inbox2.com. Those take your email
        address, and they are protected by Cloudflare Turnstile, which checks that you are a
        person and sets its own short-lived cookie to do so. We use a waitlist address to
        send you an invitation and nothing else.
      </p>

      <h2 id="cookies">Cookies</h2>
      <p>
        No analytics cookie is written until you press Accept on the banner. Decline and
        none of the vendors below ever load. Change your mind either way from{" "}
        <strong>Cookie settings</strong> at the bottom of any page, which clears what was
        set and reloads the page.
      </p>
      <div className={styles.tableWrap}>
        <table>
          <thead>
            <tr><th>Name</th><th>Set by</th><th>What it does</th><th>Lifetime</th></tr>
          </thead>
          <tbody>
            <tr>
              <td><code>inbox2.analytics-consent.v1</code></td>
              <td>inbox2</td>
              <td>Remembers whether you accepted or declined. Stored in your browser, never sent to us.</td>
              <td>Until you clear it</td>
            </tr>
            <tr>
              <td><code>_ga, _ga_*</code></td>
              <td>Google Analytics</td>
              <td>Counts visits and tells us which pages get read. IP addresses are truncated.</td>
              <td>2 years</td>
            </tr>
            <tr>
              <td><code>ph_*_posthog</code></td>
              <td>PostHog</td>
              <td>Product analytics: which pages and links people use on the way to downloading.</td>
              <td>1 year</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        Both vendors are configured for EU-hosted collection. Neither is used for
        advertising, and we run no advertising or social tracking pixels on this site.
      </p>

      <h2 id="grounds">Why we may hold it</h2>
      <ul>
        <li>
          <strong>Performance of a contract.</strong> Running the mail service you signed up
          for, including hosting mail for an inbox2 MX domain and keeping your account.
        </li>
        <li>
          <strong>Consent.</strong> Analytics cookies, and connecting a Google, Microsoft or
          IMAP account. Both are yours to withdraw at any time.
        </li>
        <li>
          <strong>Legitimate interests.</strong> Keeping the service up, blocking abuse and
          spam, and security logging. We have weighed these against your rights and kept the
          logging to what an operator needs.
        </li>
        <li>
          <strong>Legal obligation.</strong> Invoicing and tax records for paid accounts.
        </li>
      </ul>

      <h2 id="sharing">Who else touches it</h2>
      <p>
        We do not sell personal data and we have never shared it for advertising. These are
        the processors involved in running the service:
      </p>
      <div className={styles.tableWrap}>
        <table>
          <thead>
            <tr><th>Processor</th><th>What for</th><th>Where</th></tr>
          </thead>
          <tbody>
            <tr><td>Cloudflare</td><td>Edge TLS, this website, Turnstile on the forms</td><td>Global edge, EU entity</td></tr>
            <tr><td><Fill>hosting provider</Fill></td><td>The servers running the API, database and mail nodes</td><td><Fill>country and region</Fill></td></tr>
            <tr><td>Cloudflare R2</td><td>Storage of the files on Disk</td><td>European Union</td></tr>
            <tr><td>OpenAI</td><td>Server-side AI triage, paid plans, off by default</td><td>United States</td></tr>
            <tr><td>Apple, Google</td><td>Push notifications to phones (a wake-up signal, no message content)</td><td>Global</td></tr>
            <tr><td>Stripe</td><td>Payment processing for paid plans</td><td>EU and United States</td></tr>
          </tbody>
        </table>
      </div>
      <p>
        A Google, Microsoft or Meta account that you connect yourself is your provider,
        reached from your device. We are not a processor in that path.
      </p>
      <p>
        We will also hand over data where a Dutch court or a legally binding order requires
        it. Where the law lets us tell you first, we will.
      </p>

      <h2 id="retention">How long we keep it</h2>
      <p>
        Mail on an inbox2 MX domain is kept until you or your administrator deletes it, or
        until <Fill>retention period after account closure</Fill> after the account closes.
        Sessions expire after 30 days of inactivity. Push subscription leases are collected
        after 30 days. Audit logs are kept for{" "}
        <Fill>audit log retention</Fill>. Analytics data follows the vendor&rsquo;s own
        retention setting, currently <Fill>GA and PostHog retention window</Fill>.
      </p>
      <p>
        A file you delete on Disk stays in the trash for 30 days and is then removed. An
        older version of a file is kept for 180 days after a newer one replaces it. If your
        organisation leaves the paid plans, Disk is read-only for 30 days, and its files
        are deleted 90 days after the plan ended.
      </p>
      <p>
        For accounts you connect yourself, the retention question is answered by your own
        disk. Delete the app, or disconnect the account inside it, and the local copy goes.
      </p>

      <h2 id="transfers">Where it is processed</h2>
      <p>
        Our servers run in <Fill>hosting country and region</Fill>. Transfers to processors
        outside the EEA, currently OpenAI and Stripe, run on the European Commission&rsquo;s
        Standard Contractual Clauses. We do not yet offer EU-only hosting as a contractual
        guarantee, and we would rather say so here than let you assume it. If you need that
        guarantee, you can run the whole stack yourself: the apps are open source under the
        Apache 2.0 licence and the server is source-available under the Functional Source
        License (FSL-1.1).
      </p>

      <h2 id="rights">Your rights</h2>
      <p>
        Under the GDPR you can ask us for a copy of your data, correct it, delete it,
        restrict or object to how we use it, take it elsewhere in a portable format, and
        withdraw any consent you gave. Write to{" "}
        <a href="mailto:privacy@inbox2.com">privacy@inbox2.com</a> and we will answer within
        one month.
      </p>
      <p>
        Being honest about a gap: the self-service data export in the product is not
        finished yet, so a portability request today is handled by us by hand. If you are
        unhappy with how we handled anything, you can complain to the Dutch DPA, the{" "}
        <a href="https://autoriteitpersoonsgegevens.nl" target="_blank" rel="noopener">
          Autoriteit Persoonsgegevens
        </a>.
      </p>

      <h2 id="security">How it is protected</h2>
      <p>
        Traffic runs over TLS. Passwords are hashed. Credentials in the app&rsquo;s vault are
        encrypted with libsodium under a key we never hold, so a sealed domain gives us
        ciphertext we cannot open. Every organisation is isolated at the query layer, and
        cross-tenant access returns a 404 rather than a permissions error. Access to
        production is limited to the people who operate it.
      </p>
      <p>
        Two things we will say plainly, because you would find out eventually. We do not yet
        run automated off-site backups of the hosted mail database, and full client-side
        encryption is a per-domain option on paid plans. Both are being worked on, and until
        they land, weigh them.
      </p>
      <p>
        Found a security problem? Mail{" "}
        <a href="mailto:security@inbox2.com">security@inbox2.com</a> and we will answer.
      </p>

      <h2 id="changes">Changes</h2>
      <p>
        When we change this policy we update the date at the top. If a change affects what we
        do with data you already gave us, we will email account holders before it takes
        effect.
      </p>

      <h2 id="contact">Contact</h2>
      <p>
        Sadiq Beheer B.V., <Fill>registered address</Fill>, the Netherlands.{" "}
        <a href="mailto:privacy@inbox2.com">privacy@inbox2.com</a> for anything on this page,{" "}
        <a href="mailto:hello@inbox2.com">hello@inbox2.com</a> for everything else.
      </p>
    </Legal>
  );
}
