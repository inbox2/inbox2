// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

describe('ambientMotion', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.useFakeTimers()
    vi.spyOn(document, 'hasFocus').mockReturnValue(true)
  })
  afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })

  it('pauses after a minute without input, and any input resumes it', async () => {
    const anim = (iterations) => ({ playState: 'running', effect: { getTiming: () => ({ iterations }) }, pause: vi.fn(), play: vi.fn() })
    const [loop, once] = [anim(Infinity), anim(1)]
    document.getAnimations = () => [loop, once]
    const m = await import('../ambientMotion')
    const seen = vi.fn()
    m.subscribe(seen)
    expect(m.isAmbientActive()).toBe(true)

    vi.advanceTimersByTime(30_000)
    window.dispatchEvent(new Event('pointermove'))
    vi.advanceTimersByTime(45_000)
    expect(m.isAmbientActive()).toBe(true) // the input moved the deadline

    vi.advanceTimersByTime(20_000)
    expect(m.isAmbientActive()).toBe(false)
    expect(loop.pause).toHaveBeenCalled()
    expect(once.pause).not.toHaveBeenCalled() // a fade-in still finishes

    window.dispatchEvent(new Event('keydown'))
    expect(m.isAmbientActive()).toBe(true)
    expect(loop.play).toHaveBeenCalled()
    expect(seen).toHaveBeenCalledTimes(2)
  })

  it('pauses a loop that starts while nobody is here', async () => {
    const m = await import('../ambientMotion')
    m.startAmbientMotion()
    document.hasFocus.mockReturnValue(false)
    window.dispatchEvent(new Event('blur'))
    const spinner = { animationName: 'spin', playState: 'running', effect: { getTiming: () => ({ iterations: Infinity }) }, pause: vi.fn(), play: vi.fn() }
    const el = document.createElement('div')
    el.getAnimations = () => [spinner]
    document.body.append(el)
    const e = new Event('animationstart', { bubbles: true })
    e.animationName = 'spin'
    el.dispatchEvent(e)
    expect(spinner.pause).toHaveBeenCalled()
    document.hasFocus.mockReturnValue(true)
    window.dispatchEvent(new Event('focus'))
    expect(spinner.play).toHaveBeenCalled()
  })

  it('pauses at once when the window loses focus', async () => {
    const m = await import('../ambientMotion')
    m.startAmbientMotion()
    document.hasFocus.mockReturnValue(false)
    window.dispatchEvent(new Event('blur'))
    expect(m.isAmbientActive()).toBe(false)
  })
})
