import { describe, it, expect } from 'vitest'
import { peaks } from '../waveform'

describe('waveform peaks', () => {
  it('takes the loudest absolute sample per slice', () => {
    const s = new Float32Array(400)
    s[10] = -0.8
    s[150] = 0.3
    s[399] = 1.5
    expect(Array.from(peaks(s, 4)).map((v) => +v.toFixed(2))).toEqual([0.8, 0.3, 0, 1])
  })

  it('gives silence for an empty file', () => {
    expect(Array.from(peaks(new Float32Array(0), 3))).toEqual([0, 0, 0])
  })
})
