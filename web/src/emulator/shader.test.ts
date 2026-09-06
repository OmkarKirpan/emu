import { describe, expect, it } from 'vitest'
import { WgslReflect } from 'wgsl_reflect'
import { FRAME_SHADER, SHADER_INTERFACE } from './shader'

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
 * (orientation, colour); that needs eyes on a GPU.
 */
describe('FRAME_SHADER', () => {
  const reflect = new WgslReflect(FRAME_SHADER)

  it('is syntactically valid WGSL', () => {
    // Constructing `WgslReflect` throws on a parse error, so reaching here
    // is most of the assertion; this just pins down that it found the
    // shader rather than silently parsing an empty string.
    expect(reflect.entry.vertex.length + reflect.entry.fragment.length).toBeGreaterThan(0)
  })

  it('declares exactly the entry points the render pipeline names', () => {
    expect(reflect.entry.vertex.map((entry) => entry.name)).toEqual([SHADER_INTERFACE.vertexEntryPoint])
    expect(reflect.entry.fragment.map((entry) => entry.name)).toEqual([SHADER_INTERFACE.fragmentEntryPoint])
  })

  it('binds the sampler and texture where the bind group puts them', () => {
    const groups = reflect.getBindGroups()
    expect(groups.length, 'shader should declare exactly one bind group').toBe(1)

    const group = groups[0]
    expect(group[SHADER_INTERFACE.samplerBinding]?.name).toBe('frameSampler')
    expect(group[SHADER_INTERFACE.textureBinding]?.name).toBe('frameTexture')
  })
})
