// ENG-57 (M5): the two renderer backends the Worker can paint the
// framebuffer with, behind one interface -- WebGPU as a progressive
// enhancement, Canvas 2D as the load-bearing baseline. That ordering is
// ENG-57's own recommendation, and it's load-bearing in the literal sense:
// `OffscreenCanvas.getContext('webgpu')` ships by default in Chrome/Edge
// 113+, Firefox 141+ and Safari 26+, but each gates it further by OS and
// GPU, so `requestAdapter()` returning `null` on a nominally-supported
// browser is a normal outcome, not an error.
//
// Worker-only (hence the `OffscreenCanvas` parameters, and its exclusion
// from `tsconfig.app.json` -- see `tsconfig.worker.json`).
import { DISPLAY_FILTERS, filteredCanvasSize, type DisplayFilterKind, type DisplayFilterSettings } from './displayFilter'
import { CRT_PARAMS_FLOATS, FRAME_SHADER, packCrtParams, SHADER_INTERFACE } from './shader'
import type { RendererKind } from './protocol'

export interface FrameRenderer {
  /** Which backend actually got stood up -- reported to the main thread and
   * shown in the UI, so "did WebGPU engage?" is answerable at a glance
   * rather than by inference. */
  readonly kind: RendererKind
  /**
   * Paints one resolved RGBA8 frame. Called once per Worker tick.
   *
   * `Uint8ClampedArray<ArrayBuffer>`, not the default
   * `Uint8ClampedArray<ArrayBufferLike>`: the buffer must be a *non-shared*
   * one, because `ImageData` refuses shared-buffer-backed views at runtime
   * ("The provided Uint8ClampedArray value must not be shared") and the
   * Canvas 2D path builds an `ImageData` per frame. `NesCore.stepFrame`
   * already hands back exactly that -- a plain copy, for this very reason
   * -- so the signature just states the requirement instead of leaving it
   * to be rediscovered.
   */
  draw(frame: Uint8ClampedArray<ArrayBuffer>): void
  /**
   * Applies a display filter (`displayFilter.ts`) and the canvas's current
   * on-screen width in device pixels -- `null` until the main thread has
   * measured it -- then repaints the last frame, so a change shows at once
   * even while the transport is paused and nothing else is drawing.
   */
  setDisplay(settings: DisplayFilterSettings, displayWidth: number | null): void
}

/**
 * Stands up the best available backend for `canvas`, falling back to Canvas
 * 2D whenever WebGPU can't be brought all the way up.
 *
 * **The ordering here is the whole point and is not rearrangeable.** A
 * canvas's context type is permanent: the first successful `getContext` call
 * fixes it for the life of the canvas, and `getContext('2d')` afterwards
 * returns null. So every step that can fail -- adapter, device, shader
 * module, pipeline -- happens *before* `getContext('webgpu')` is called at
 * all. Claiming the canvas first and validating second would mean a WGSL
 * typo doesn't degrade to Canvas 2D, it takes the canvas down with it.
 *
 * `createRenderPipelineAsync` (rather than `createRenderPipeline`) is part
 * of that: it rejects on shader-compilation and pipeline-validation errors
 * instead of surfacing them out-of-band through an error scope, which is
 * exactly the "a bad shader falls back" behaviour this needs.
 *
 * The one irreducible risk window is between `getContext('webgpu')`
 * succeeding and `configure()` returning: a throw in there leaves the
 * canvas claimed with nothing able to draw to it. `configure` is given a
 * device already proven good and `getPreferredCanvasFormat()`'s own format,
 * so there's nothing left for it to reject -- but if it ever does, that
 * throws rather than pretending a fallback is still possible.
 */
export async function createRenderer(
  canvas: OffscreenCanvas,
  width: number,
  height: number,
  preferred?: RendererKind,
): Promise<FrameRenderer> {
  if (preferred !== 'canvas2d') {
    const webgpu = await tryCreateWebGpuRenderer(canvas, width, height)
    if (webgpu) return webgpu
  }

  const canvas2d = createCanvas2dRenderer(canvas, width, height)
  if (canvas2d) return canvas2d
  throw new Error('Neither WebGPU nor Canvas 2D is available in this browser.')
}

function createCanvas2dRenderer(canvas: OffscreenCanvas, width: number, height: number): FrameRenderer | null {
  const ctx = canvas.getContext('2d')
  if (!ctx) return null
  return {
    kind: 'canvas2d',
    draw(frame) {
      ctx.putImageData(new ImageData(frame, width, height), 0, 0)
    },
    // Filters are WebGPU-only: curvature and colour fringing are per-pixel
    // resampling, which Canvas 2D has no way to express. The UI disables
    // the setting on this backend rather than offering a partial version.
    setDisplay() {},
  }
}

async function tryCreateWebGpuRenderer(
  canvas: OffscreenCanvas,
  width: number,
  height: number,
): Promise<FrameRenderer | null> {
  try {
    // `WorkerNavigator.gpu` is exposed in dedicated workers in all three
    // engines that ship WebGPU at all (ENG-57), so this doesn't need a
    // round trip to the main thread to feature-detect.
    if (!navigator.gpu) return null

    const adapter = await navigator.gpu.requestAdapter()
    if (!adapter) return null // supported browser, unsupported GPU/OS -- ENG-57's flagged normal case
    const device = await adapter.requestDevice()

    const format = navigator.gpu.getPreferredCanvasFormat()
    const module = device.createShaderModule({ code: FRAME_SHADER })
    // An explicit layout rather than `'auto'`: there is one pipeline per
    // display filter, and they all share one bind group, which only works if
    // they share one layout. `'auto'` would derive a different layout per
    // pipeline from just the bindings each entry point happens to touch.
    const bindGroupLayout = device.createBindGroupLayout({
      entries: [
        { binding: SHADER_INTERFACE.samplerBinding, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
        { binding: SHADER_INTERFACE.textureBinding, visibility: GPUShaderStage.FRAGMENT, texture: {} },
        { binding: SHADER_INTERFACE.crtParamsBinding, visibility: GPUShaderStage.FRAGMENT, buffer: {} },
        { binding: SHADER_INTERFACE.smoothSamplerBinding, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
      ],
    })
    const layout = device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] })
    // Every filter's pipeline is compiled up front, here in the fallible
    // section: a broken CRT shader has to fall back to Canvas 2D at startup,
    // not fail the first time someone switches the filter on.
    const pipelines = Object.fromEntries(
      await Promise.all(
        DISPLAY_FILTERS.map(
          async (filter) =>
            [
              filter,
              await device.createRenderPipelineAsync({
                layout,
                vertex: { module, entryPoint: SHADER_INTERFACE.vertexEntryPoint },
                fragment: { module, entryPoint: SHADER_INTERFACE.fragmentEntryPoints[filter], targets: [{ format }] },
                primitive: { topology: 'triangle-list' },
              }),
            ] as const,
        ),
      ),
    ) as Record<DisplayFilterKind, GPURenderPipeline>

    const texture = device.createTexture({
      size: [width, height],
      format: 'rgba8unorm',
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    })
    // Nearest, not linear: the framebuffer is displayed upscaled, and the
    // CSS side already commits to `image-rendering: pixelated`. Filtering
    // here would blur exactly what that's there to keep crisp.
    const sampler = device.createSampler({ magFilter: 'nearest', minFilter: 'nearest' })
    // The CRT path's sampler. Linear, but only ever read through the
    // shader's `sampleSharp`, which keeps pixel edges crisp anyway -- see
    // that function.
    const smoothSampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' })
    const crtParams = device.createBuffer({
      size: CRT_PARAMS_FLOATS * Float32Array.BYTES_PER_ELEMENT,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    })
    const bindGroup = device.createBindGroup({
      layout: bindGroupLayout,
      entries: [
        { binding: SHADER_INTERFACE.samplerBinding, resource: sampler },
        { binding: SHADER_INTERFACE.textureBinding, resource: texture.createView() },
        { binding: SHADER_INTERFACE.crtParamsBinding, resource: { buffer: crtParams } },
        { binding: SHADER_INTERFACE.smoothSamplerBinding, resource: smoothSampler },
      ],
    })

    // Everything fallible is now behind us -- only here does the canvas
    // become permanently a WebGPU canvas. See this module's doc comment.
    const context = canvas.getContext('webgpu')
    if (!context) return null
    context.configure({ device, format, alphaMode: 'opaque' })

    // A lost device can't be recovered into Canvas 2D (the canvas is
    // claimed), so this can only report. It's rare -- driver reset, or the
    // GPU process going away -- and loud in the console is better than a
    // silently frozen picture.
    void device.lost.then((info) => {
      console.error(`WebGPU device lost (${info.reason}): ${info.message}`)
    })

    let pipeline = pipelines.none

    /** Draws whatever `texture` holds now -- the last frame `draw` uploaded,
     * or black before the first -- through the current filter. */
    const present = () => {
      const encoder = device.createCommandEncoder()
      const pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: context.getCurrentTexture().createView(),
            loadOp: 'clear',
            storeOp: 'store',
            clearValue: { r: 0, g: 0, b: 0, a: 1 },
          },
        ],
      })
      pass.setPipeline(pipeline)
      pass.setBindGroup(0, bindGroup)
      pass.draw(3)
      pass.end()
      device.queue.submit([encoder.finish()])
    }

    return {
      kind: 'webgpu',
      draw(frame) {
        // Uploads the same `Uint8ClampedArray` copy the Canvas 2D path
        // draws, rather than reading wasm memory directly. `writeTexture`
        // would accept a `SharedArrayBuffer`-backed view (unlike
        // `ImageData`), so a zero-copy path exists here -- deliberately not
        // taken, since it would fork the renderer interface for a 245KB
        // memcpy that has never shown up as a cost.
        device.queue.writeTexture(
          { texture },
          frame,
          { bytesPerRow: width * 4, rowsPerImage: height },
          { width, height },
        )
        present()
      },
      setDisplay(settings, displayWidth) {
        // Unfiltered stays at the framebuffer's own size, with CSS doing the
        // upscale exactly as before filters existed. A filter needs a canvas
        // pixel per screen pixel -- see `filteredCanvasSize`. Resizing is
        // safe here, after `getContext('webgpu')`: the configured context
        // just hands out textures of the new size from `getCurrentTexture`.
        const size =
          settings.filter === 'none'
            ? { width, height }
            : filteredCanvasSize(displayWidth, width, height, device.limits.maxTextureDimension2D)
        if (canvas.width !== size.width) canvas.width = size.width
        if (canvas.height !== size.height) canvas.height = size.height
        pipeline = pipelines[settings.filter]
        device.queue.writeBuffer(crtParams, 0, packCrtParams(settings.crt, size.width, size.height, width, height))
        present()
      },
    }
  } catch (err: unknown) {
    // Any failure at all -- no adapter, device request rejected, shader
    // compile error, pipeline validation -- is a fallback, not a crash.
    // Logged rather than swallowed: "why am I on Canvas 2D?" should be
    // answerable from the console.
    console.warn('WebGPU renderer unavailable, falling back to Canvas 2D:', err)
    return null
  }
}
