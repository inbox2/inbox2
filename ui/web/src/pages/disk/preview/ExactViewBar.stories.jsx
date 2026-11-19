import '../../../styles/management.css'
import ExactViewBar from './ExactViewBar'
import { EXACT } from '../../../lib/disk/engine/logic'

export default {
  title: 'Disk/ExactViewBar',
  component: ExactViewBar,
  args: { downloadSize: 77 * 1024 ** 2, installSize: 247 * 1024 ** 2, quick: true },
  render: (args) => <div className="management"><ExactViewBar {...args} /></div>,
}

export const Offer = { args: { state: EXACT.OFFER } }
export const OfferWithoutQuickView = { args: { state: EXACT.OFFER, quick: false } }
export const LowStorage = { args: { state: EXACT.CONFIRM } }
export const Downloading = { args: { state: EXACT.DOWNLOADING, loaded: 31 * 1024 ** 2, total: 77 * 1024 ** 2 } }
export const Preparing = { args: { state: EXACT.VERIFYING } }
export const Ready = { args: { state: EXACT.READY } }
export const Converting = { args: { state: EXACT.CONVERTING } }
export const OutOfStorage = { args: { state: EXACT.FAILED, error: 'Your device is out of storage for the engine. Quick view still works.' } }
export const AskAlways = { args: { state: EXACT.ASK_ALWAYS } }
