import { afterEach, describe, expect, it } from 'vitest'
import { isDebugMode } from './debugMode'

function setSearch(search: string) {
  window.history.pushState({}, '', `/${search}`)
}

afterEach(() => setSearch(''))

describe('isDebugMode', () => {
  it('is false with no query parameters', () => {
    setSearch('')
    expect(isDebugMode()).toBe(false)
  })

  it('is false for an unrelated query parameter', () => {
    setSearch('?renderer=canvas2d')
    expect(isDebugMode()).toBe(false)
  })

  it('is true for bare ?debug', () => {
    setSearch('?debug')
    expect(isDebugMode()).toBe(true)
  })

  it('is true regardless of the value given -- presence-only, like ?renderer=', () => {
    setSearch('?debug=false')
    expect(isDebugMode()).toBe(true)
  })

  it('is true alongside other parameters', () => {
    setSearch('?renderer=canvas2d&debug')
    expect(isDebugMode()).toBe(true)
  })
})
