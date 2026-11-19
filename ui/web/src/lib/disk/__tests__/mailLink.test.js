import { describe, expect, it } from 'vitest'
import { mayLinkInstead } from '../mail'

const domains = [{ name: 'open.test', e2ee_enabled: false }, { name: 'sealed.test', e2ee_enabled: true }]

describe('mayLinkInstead', () => {
  it('allows an unsealed domain and refuses a sealed one, whatever the case', () => {
    expect(mayLinkInstead({ domains, fromAddress: 'a@open.test' })).toBe(true)
    expect(mayLinkInstead({ domains, fromAddress: 'a@SEALED.test' })).toBe(false)
  })
  it('refuses a sealed domain even when a provider account sends it', () => {
    expect(mayLinkInstead({ domains, fromAddress: 'a@sealed.test', viaProvider: true })).toBe(false)
  })
  it('stays closed for an inbox2 From on an unknown domain, open for a provider account', () => {
    expect(mayLinkInstead({ domains, fromAddress: 'a@other.test' })).toBe(false)
    expect(mayLinkInstead({ domains: undefined, fromAddress: '' })).toBe(false)
    expect(mayLinkInstead({ domains, fromAddress: 'me@gmail.test', viaProvider: true })).toBe(true)
  })
})
