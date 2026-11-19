import { ContextGroup, ContextField, ContextRow, CollaboratorRow } from './ContextPanel'
import Avatar from '../Avatar'

export default {
  title: 'Components/ContextPanel',
  component: ContextGroup,
}

export const SingleField = {
  render: () => (
    <div data-theme="dark">
      <ContextField label="Subject">Re: Q4 Budget Review</ContextField>
    </div>
  ),
}

export const MonoField = {
  render: () => (
    <div data-theme="dark">
      <ContextField label="Message ID" mono>msg_aB3xK9mNpQ2r</ContextField>
    </div>
  ),
}

export const FieldRow = {
  render: () => (
    <div data-theme="dark">
      <ContextRow>
        <ContextField label="Status">Open</ContextField>
        <ContextField label="Priority">Normal</ContextField>
      </ContextRow>
    </div>
  ),
}

export const CollaboratorViewing = {
  render: () => (
    <div data-theme="dark">
      <CollaboratorRow
        avatar={<Avatar name="Sarah Chen" size={18} />}
        name="Sarah Chen"
        viewing
      />
    </div>
  ),
}

export const CollaboratorWithDetail = {
  render: () => (
    <div data-theme="dark">
      <CollaboratorRow
        avatar={<Avatar name="Alex Kim" size={18} />}
        name="Alex Kim"
        detail="Last seen 2h ago"
      />
    </div>
  ),
}

export const FullPanel = {
  render: () => (
    <div data-theme="dark">
      <ContextGroup icon="doc.text.fill" title="Details">
        <ContextRow>
          <ContextField label="Status">Open</ContextField>
          <ContextField label="Priority">Normal</ContextField>
        </ContextRow>
        <ContextField label="Subject">Re: Q4 Budget Review</ContextField>
        <ContextField label="Message ID" mono>msg_aB3xK9mNpQ2r</ContextField>
      </ContextGroup>
      <ContextGroup icon="person.fill" title="Collaborators" accent>
        <CollaboratorRow
          avatar={<Avatar name="Sarah Chen" size={18} />}
          name="Sarah Chen"
          viewing
        />
        <CollaboratorRow
          avatar={<Avatar name="Alex Kim" size={18} />}
          name="Alex Kim"
          detail="Last seen 2h ago"
        />
        <CollaboratorRow
          avatar={<Avatar name="Maria Lopez" size={18} />}
          name="Maria Lopez"
          detail="Assigned"
        />
      </ContextGroup>
      <ContextGroup icon="tag.fill" title="Tags">
        <ContextField label="Tags">Finance, Urgent</ContextField>
      </ContextGroup>
    </div>
  ),
}
