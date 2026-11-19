import RemoteContentBanner from './RemoteContentBanner'
import ProxyFailedBanner from './ProxyFailedBanner'

const noop = () => {}

export default {
  title: 'Components/RemoteContentBanner',
  component: RemoteContentBanner,
}

export const SingleImage = {
  render: () => (
    <RemoteContentBanner
      count={1}
      onShowOnce={noop}
      onAlwaysSender={noop}
      onAlwaysAll={noop}
    />
  ),
}

export const ManyImages = {
  render: () => (
    <RemoteContentBanner
      count={12}
      onShowOnce={noop}
      onAlwaysSender={noop}
      onAlwaysAll={noop}
    />
  ),
}

export const ProxyFailed = {
  render: () => <ProxyFailedBanner count={8} onLoadDirect={noop} />,
}

export const ProxyFailedSingle = {
  render: () => <ProxyFailedBanner count={1} onLoadDirect={noop} />,
}
