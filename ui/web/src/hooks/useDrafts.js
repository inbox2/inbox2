import { useContext } from 'react'
import DraftContext from './DraftContext'

export default function useDrafts() {
  const context = useContext(DraftContext)
  if (!context) {
    throw new Error('useDrafts must be used within a DraftProvider')
  }
  return context
}
