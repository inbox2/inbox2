import Linkify from './Linkify'

export default {
  title: 'Components/Linkify',
  component: Linkify,
}

export const Default = {
  render: () => (
    <p>
      <Linkify text="Join the call at https://meet.inbox2.dev/dana-lee or reply here." />
    </p>
  ),
}

export const MultipleUrls = {
  render: () => (
    <p>
      <Linkify text="Docs are at https://inbox2.dev/docs and the repo is https://github.com/inbox2/web. See https://inbox2.dev/changelog." />
    </p>
  ),
}

export const PlainText = {
  render: () => (
    <p>
      <Linkify text="No links here — just a plain note about tomorrow's review meeting." />
    </p>
  ),
}

export const TrailingPunctuation = {
  render: () => (
    <p>
      <Linkify text="Have a look at https://inbox2.dev/pricing." />
    </p>
  ),
}
