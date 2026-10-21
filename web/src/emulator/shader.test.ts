import { describe, expect, it } from 'vitest'
import { WgslReflect } from 'wgsl_reflect'
import { DISPLAY_FILTERS } from './displayFilter'
import { CRT_PARAMS_FLOATS, CRT_PARAMS_LAYOUT, FRAME_SHADER, packCrtParams, SHADER_INTERFACE } from './shader'

/**
 * The WebGPU renderer's shader is the one piece of this codebase that no
 * test environment here can actually run: CI runners have no GPU, and even
 * locally `navigator.gpu` is absent from the sandboxed Chromium this repo's
 * e2e suite drives. A broken shader would therefore surface only as
 * `renderer.ts` quietly falling back to Canvas 2D on a real machine --
 * correct behaviour, and completely silent.
 *
 * So this parses it instead. `wgsl_reflect` is a pure-JS WGSL parser, which
 * catches the failure mode that actually matters here -- a syntax error, a
 * renamed entry point, a moved binding -- and asserts the shader's declared
 * interface still matches the pipeline and bind group `renderer.ts` builds
 * around it. What it can't tell you is whether the *image* comes out right
 * (orientation, colour, how strong the CRT effects look); that needs eyes on
 * a GPU.
 */
describe('FRAME_SHADER', () => {
  const reflect = new WgslReflect(FRAME_SHADER)

  it('is syntactically valid WGSL', () => {
    // Constructing `WgslReflect` throws on a parse error, so reaching here
    // is most of the assertion; this just pins down that it found the
    // shader rather than silently parsing an empty string.
    expect(reflect.entry.vertex.length + reflect.entry.fragment.length).toBeGreaterThan(0)
  })

  it('declares exactly the entry points the render pipelines name', () => {
    expect(reflect.entry.vertex.map((entry) => entry.name)).toEqual([SHADER_INTERFACE.vertexEntryPoint])
    expect(reflect.entry.fragment.map((entry) => entry.name).sort()).toEqual(
      Object.values(SHADER_INTERFACE.fragmentEntryPoints).sort(),
    )
  })

  it('has a fragment entry point for every display filter', () => {
    const declared = reflect.entry.fragment.map((entry) => entry.name)
    for (const filter of DISPLAY_FILTERS) {
      expect(declared).toContain(SHADER_INTERFACE.fragmentEntryPoints[filter])
    }
  })

  it('binds every resource where the bind group puts it', () => {
    const groups = reflect.getBindGroups()
    expect(groups.length, 'shader should declare exactly one bind group').toBe(1)

    const group = groups[0]
    expect(group[SHADER_INTERFACE.samplerBinding]?.name).toBe('frameSampler')
    expect(group[SHADER_INTERFACE.textureBinding]?.name).toBe('frameTexture')
    expect(group[SHADER_INTERFACE.crtParamsBinding]?.name).toBe('crt')
    expect(group[SHADER_INTERFACE.smoothSamplerBinding]?.name).toBe('smoothSampler')
  })

  it("sizes the CRT uniform buffer exactly as large as the shader's struct", () => {
    const crt = reflect.uniforms.find((u) => u.binding === SHADER_INTERFACE.crtParamsBinding)
    expect(crt?.size).toBe(CRT_PARAMS_FLOATS * 4)
  })

  // The drift this file exists to catch: reorder a field in the WGSL struct
  // and forget `CRT_PARAMS_LAYOUT`, and scanlines would quietly start
  // reading the curvature flag.
  it("packs each CRT field at the struct member's own offset", () => {
    const crt = reflect.uniforms.find((u) => u.binding === SHADER_INTERFACE.crtParamsBinding)
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
