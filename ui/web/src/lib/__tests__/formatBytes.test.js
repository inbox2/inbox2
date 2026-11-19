import { describe, it, expect } from 'vitest'
import formatBytes from '../formatBytes'

describe('formatBytes', () => {
  it('scales through B, KB, MB, GB and TB', () => {
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(14_680_064)).toBe('14.0 MB')
    expect(formatBytes(10 * 1024 ** 3)).toBe('10.0 GB')
    expect(formatBytes(1.5 * 1024 ** 4)).toBe('1.5 TB')
  })

  it('stays in TB past it, and handles empty input', () => {
    expect(formatBytes(2048 * 1024 ** 4)).toBe('2048.0 TB')
    expect(formatBytes(null)).toBe('0 B')
  })
})
