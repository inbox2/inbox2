import '../../styles/management.css';
import MgmtSelect from './MgmtSelect';
import MgmtField from './MgmtField';

/* The ONE styled <select> (see MgmtSelect.jsx) — every dropdown in the app
 * goes through it. Rendered under the `management` token scope like the
 * console; outside that scope its --m-* tokens fall back to the main app's
 * theme tokens. */
export default {
  title: 'Management/MgmtSelect',
  component: MgmtSelect,
};

const FRUIT = [
  { value: 'apple', label: 'Apple' },
  { value: 'pear', label: 'Pear' },
  { value: 'plum', label: 'Plum' },
];

export const Labelled = {
  render: () => (
    <div className="management">
      <MgmtSelect
        label="Fruit"
        hint="Mono uppercase label + hint, matching MgmtField."
        options={FRUIT}
        defaultValue="pear"
      />
    </div>
  ),
};

export const Placeholder = {
  render: () => (
    <div className="management">
      <MgmtSelect label="Fruit" placeholder="Choose a fruit…" options={FRUIT} defaultValue="" />
    </div>
  ),
};

export const Bare = {
  render: () => (
    /* No label wrapper — for rows that render their own label. Natural width
       in a row context, full width in a block context, like a raw <select>. */
    <div className="management">
      <MgmtSelect bare options={FRUIT} aria-label="Fruit" />
    </div>
  ),
};

export const CompactRow = {
  render: () => (
    /* Compact (38px) controls inline with a text input — the condition-row
       usage (field / operator / value). */
    <div className="management">
      <MgmtSelect bare compact options={['to', 'from', 'subject']} aria-label="Field" />{' '}
      <MgmtSelect bare compact options={['contains', 'is exactly']} aria-label="Operator" />
    </div>
  ),
};

export const Disabled = {
  render: () => (
    <div className="management">
      <MgmtSelect label="Fruit" options={FRUIT} disabled defaultValue="apple" />
    </div>
  ),
};

export const WithSiblingField = {
  render: () => (
    /* Labelled select next to a MgmtField — same control metrics. */
    <div className="management">
      <MgmtField label="Name" placeholder="e.g. Backup script" />
      <MgmtSelect label="Access" options={FRUIT} defaultValue="apple" />
    </div>
  ),
};
