import { describe, expect, it } from 'vitest'
import { WgslReflect } from 'wgsl_reflect'
import { DISPLAY_FILTERS } from './displayFilter'
import { CRT_PARAMS_FLOATS, CRT_PARAMS_LAYOUT, FILTER_SHADERS, packCrtParams, SHADER_INTERFACE } from './shader'

/**
 * The WebGPU renderer's shaders are the one piece of this codebase that no
 * test environment here can actually run: CI runners have no GPU, and the
 * Chromium Playwright bundles doesn't expose `navigator.gpu` either. A
 * shader that fails to compile surfaces only on a real machine, as
 * `renderer.ts` falling back -- to Canvas 2D for the plain shader, to "this
 * filter is unavailable" for a filter's -- with nothing but a console
 * message to say why.
 *
 * So this parses them instead. `wgsl_reflect` is a pure-JS WGSL parser, which
 * catches a syntax error, a renamed entry point or a moved binding, and lets
 * each shader's declared interface be checked against the pipelines and bind
 * group `renderer.ts` builds around it. It does *not* type-check: a type
 * error parses fine and only fails on a GPU. Nor can it tell you whether the
 * *image* comes out right (orientation, colour, how strong the CRT effects
 * look); that needs eyes on a GPU.
 */

/** The name the WGSL gives each slot of the one bind group every filter
 * shares. A shader declaring any other slot is one `renderer.ts`'s bind
 * group layout doesn't provide. */
const BINDING_NAMES: Record<number, string> = {
  [SHADER_INTERFACE.samplerBinding]: 'frameSampler',
  [SHADER_INTERFACE.textureBinding]: 'frameTexture',
  [SHADER_INTERFACE.crtParamsBinding]: 'crt',
  [SHADER_INTERFACE.smoothSamplerBinding]: 'smoothSampler',
}

describe.each(DISPLAY_FILTERS)("the '%s' filter's shader", (filter) => {
  const reflect = new WgslReflect(FILTER_SHADERS[filter])

  it('is syntactically valid WGSL', () => {
    // Constructing `WgslReflect` throws on a parse error, so reaching here
    // is most of the assertion; this just pins down that it found the
    // shader rather than silently parsing an empty string.
    expect(reflect.entry.vertex.length + reflect.entry.fragment.length).toBeGreaterThan(0)
  })

  it('declares the shared vertex stage and exactly its own fragment entry point', () => {
    expect(reflect.entry.vertex.map((entry) => entry.name)).toEqual([SHADER_INTERFACE.vertexEntryPoint])
    expect(reflect.entry.fragment.map((entry) => entry.name)).toEqual([SHADER_INTERFACE.fragmentEntryPoints[filter]])
  })

  it('binds only slots the shared bind group provides, each under its own name', () => {
    const groups = reflect.getBindGroups()
    expect(groups.length, 'shader should declare exactly one bind group').toBe(1)
    groups[0].forEach((variable, binding) => {
      if (variable) expect(variable.name, `binding ${binding}`).toBe(BINDING_NAMES[binding])
    })
  })
})

describe("the CRT shader's uniform", () => {
  const crt = new WgslReflect(FILTER_SHADERS.crt).uniforms.find(
    (u) => u.binding === SHADER_INTERFACE.crtParamsBinding,
  )

  it('is exactly as large as the buffer the renderer allocates', () => {
    expect(crt?.size).toBe(CRT_PARAMS_FLOATS * 4)
  })

  // The drift this file exists to catch: reorder a field in the WGSL struct
  // and forget `CRT_PARAMS_LAYOUT`, and scanlines would quietly start
  // reading the curvature flag.
  it("packs each field at the struct member's own offset", () => {
    const members = crt?.members ?? []
    expect(members.map((m) => m.name).sort()).toEqual(Object.keys(CRT_PARAMS_LAYOUT).sort())
    for (const member of members) {
      expect(member.offset / 4, member.name).toBe(CRT_PARAMS_LAYOUT[member.name as keyof typeof CRT_PARAMS_LAYOUT])
    }
  })
})

describe('packCrtParams', () => {
  it('writes sizes as floats and each option as a 0/1 strength', () => {
    const packed = packCrtParams(
      { scanlines: true, curvature: false, chromaticAberration: true, vignette: false },
      920,
      863,
      256,
      240,
    )
    expect(packed).toHaveLength(CRT_PARAMS_FLOATS)
    expect(packed[CRT_PARAMS_LAYOUT.outputSize]).toBe(920)
    expect(packed[CRT_PARAMS_LAYOUT.outputSize + 1]).toBe(863)
    expect(packed[CRT_PARAMS_LAYOUT.sourceSize]).toBe(256)
    expect(packed[CRT_PARAMS_LAYOUT.sourceSize + 1]).toBe(240)
    expect(packed[CRT_PARAMS_LAYOUT.scanlines]).toBe(1)
    expect(packed[CRT_PARAMS_LAYOUT.curvature]).toBe(0)
    expect(packed[CRT_PARAMS_LAYOUT.chromaticAberration]).toBe(1)
    expect(packed[CRT_PARAMS_LAYOUT.vignette]).toBe(0)
  })
})
