import { useEffect, useRef } from 'react';
import SpaceTreemap from './SpaceTreemap';
import styles from './SpaceTreemap.stories.module.css';

/* Harness for the Spaces board's cell layout: real-shaped data (a full inbox
 * across differently sized cells) so the responsive behaviour — where the list
 * sits, what a row drops as it narrows — can be checked at a glance instead of
 * guessed at. `Board` mirrors a wide desktop window; `Narrow` squeezes the same
 * cells until every one is in its stacked layout. */

export default {
  title: 'Spaces/SpaceTreemap',
  component: SpaceTreemap,
  parameters: { layout: 'fullscreen' },
};

const row = (from, subject, label, date, priority) => ({
  id: `${from}-${subject}`,
  from,
  subject,
  preview: 'Beste heer Sadiq, graag ontvangen wij van u de gevraagde stukken…',
  provider: 'gmail',
  date,
  unread: false,
  labelChip: label ? { badge: label, tone: 'neutral' } : null,
  priorityChip: priority ? { badge: priority, tone: 'warn' } : null,
  assignees: [],
});

const space = (id, name, open, openness = 'org') => ({
  id,
  key: `spc_${id}`,
  slug: id,
  name,
  icon: 'globe',
  color: null,
  openness,
  members: [],
  open,
  unread: 0,
  volume: open,
  unassigned: null,
});

const spaces = [
  space('finance', 'Finance', 14),
  space('operations', 'Operations', 10),
  space('sales', 'Sales', 6),
  space('support', 'Support', 0),
  space('marketing', 'Marketing', 0),
  space('reading', 'Reading', 1, 'personal'),
  space('personal', 'Personal', 0, 'personal'),
  space('triage', 'Triage', 2),
];

const messagesBySpace = {
  finance: [
    row('Mohamed Ebrahim', 'VAT Tax Group Update – EPICO Entity', 'Action', 'Sep 30', 'High'),
    row('Chadi Samir Richani', 'EPICO-Revenue Recog- Oct-2025', 'Reply', 'Nov 10'),
    row('Chadi Samir Richani', 'Actual vs. Budget EPICO June-25', 'Others', 'Oct 16'),
    row('Facturatie Moller Auto', 'factuurnummer 1186795 (DossierNr 258299)', 'Action', 'Jul 31'),
    row('Rizwan Malik', 'Consolidated Status Update – VAT Points', 'Action', 'Sep 17'),
    row('Suleman Chaudary', 'Bevestiging termijnregeling belastingschuld', 'Reply', 'Jul 15'),
    row('Belastingdienst', 'Package Submission Invitation', 'Reply', 'Jul 6'),
    row('Administratie - Ally', 'Factuur oktober 2026', 'Action', 'Sep 15'),
  ],
  operations: [
    row('Amazon Web Services', 'Action Required: AWS Account Alert', 'Action', 'Sep 18', 'High'),
    row('Chadi Samir Richani', 'Approval Request: Upcoming Production', 'Action', 'Aug 6', 'High'),
    row('Mohamed Ebrahim', 'Role Definitions & Access Details', 'Others', 'Nov 14', 'High'),
    row('Chadi Samir Richani', 'TULI ERP Walkthrough Report', 'Reply', 'Jun 27'),
    row('InhuurdeskPGGM', 'Intake Waseem Sadiq SRQ116790', 'Schedule', 'Sep 18'),
    row('Esther van den Hoek', 'oprichting Husttle B.V. / 098811.01', 'Action', 'Aug 21'),
    row('Mohamed Ebrahim', 'GP UAT DB Access', null, 'Oct 16'),
  ],
  sales: [
    row('Mo Tarrahi', 'Marjan PROCUREMENT & CRM MANAGEMENT', 'Reply', 'Jul 24'),
    row('Ali Shan', 'Spreadsheet shared with you: LEADS', null, 'Oct 7'),
    row('The Oriental Hybrid', 'Discussion: Strategic Partnership', 'Reply', 'Aug 27'),
    row('Shaheen', 'IRR Slide deck', null, 'Aug 22'),
  ],
  reading: [row('speedrun', 'Nicolas Kopp: Take the wedge every single time', null, 'Sep 16')],
  triage: [
    row('Dit is een automatisch bericht', 'Bevestiging bezoek', 'Schedule', 'Sep 18'),
    row('Nicolas Ha', 'Spam filter engine for your email client', 'Waiting', 'Jul 4'),
  ],
};

// Size comes from a ref-set custom property — inline styles are banned (F1).
function Frame({ width, height = 900 }) {
  const ref = useRef(null);
  useEffect(() => {
    ref.current?.style.setProperty('--frame-w', `${width}px`);
    ref.current?.style.setProperty('--frame-h', `${height}px`);
  }, [width, height]);
  return (
    <div ref={ref} className={styles.frame}>
      <SpaceTreemap spaces={spaces} metric="open" messagesBySpace={messagesBySpace} />
    </div>
  );
}

export const Board = { render: () => <Frame width={1900} /> };
export const Medium = { render: () => <Frame width={1200} /> };
export const Narrow = { render: () => <Frame width={760} height={800} /> };
