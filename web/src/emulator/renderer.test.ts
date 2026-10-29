/// <reference types="@webgpu/types" />
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_DISPLAY_FILTER, type DisplayFilterSettings } from './displayFilter'
import { createRenderer } from './renderer'

const CRT: DisplayFilterSettings = {
  filter: 'crt',
  crt: { scanlines: false, curvature: true, chromaticAberration: false, vignette: true },
}

/** Only models the WebGPU calls the renderer consumes. These tests exercise
 * backend selection and frame submission, not shader compilation or pixels;
 * the latter still need the real-browser suite. */
function setupRenderer() {
  const plainPipeline = { label: 'plain' }
  const crtPipeline = { label: 'crt' }
  const texture = { createView: vi.fn(() => ({ label: 'source view' })) }
  const uniform = { label: 'CRT uniform' }
  const bindGroup = { label: 'shared bind group' }
  const pass = {
    setPipeline: vi.fn(),
    setBindGroup: vi.fn(),
    draw: vi.fn(),
    end: vi.fn(),
  }
  const encoder = {
    beginRenderPass: vi.fn(() => pass),
    finish: vi.fn(() => ({ label: 'command buffer' })),
  }
  const queue = { writeTexture: vi.fn(), writeBuffer: vi.fn(), submit: vi.fn() }
  const device = {
    pushErrorScope: vi.fn(),
    popErrorScope: vi.fn<() => Promise<{ message: string } | null>>().mockResolvedValue(null),
    createBindGroupLayout: vi.fn(() => ({})),
    createPipelineLayout: vi.fn(() => ({})),
    createShaderModule: vi.fn(() => ({})),
    createRenderPipelineAsync: vi.fn()
      .mockResolvedValueOnce(plainPipeline)
      .mockResolvedValue(crtPipeline),
    createTexture: vi.fn(() => texture),
    createSampler: vi.fn(() => ({})),
    createBuffer: vi.fn(() => uniform),
    createBindGroup: vi.fn(() => bindGroup),
    createCommandEncoder: vi.fn(() => encoder),
    limits: { maxTextureDimension2D: 4096 },
    queue,
    lost: new Promise<GPUDeviceLostInfo>(() => {}),
    onuncapturederror: null as ((event: { error: { message: string } }) => void) | null,
  }
  const adapter = { requestDevice: vi.fn().mockResolvedValue(device) }
  const gpu = {
    requestAdapter: vi.fn().mockResolvedValue(adapter),
    getPreferredCanvasFormat: vi.fn(() => 'bgra8unorm'),
  }
  const context = {
    configure: vi.fn(),
    getCurrentTexture: vi.fn(() => ({ createView: () => ({ label: 'output view' }) })),
  }
  const canvas2d = { putImageData: vi.fn() }
  const canvas = {
    width: 256,
    height: 240,
    getContext: vi.fn((kind: string) => kind === 'webgpu' ? context : canvas2d),
  }

  vi.stubGlobal('navigator', { gpu })
  vi.stubGlobal('GPUShaderStage', { FRAGMENT: 2 })
  vi.stubGlobal('GPUTextureUsage', { COPY_DST: 2, TEXTURE_BINDING: 4 })
  vi.stubGlobal('GPUBufferUsage', { COPY_DST: 8, UNIFORM: 64 })

  return {
    canvas, canvas2d, context, gpu, adapter, device, queue, texture, uniform,
    pass, bindGroup, plainPipeline, crtPipeline,
    create: () => createRenderer(canvas as unknown as OffscreenCanvas, 256, 240),
  }
}

describe('renderer display filters', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('offers both filters only after setup has been validated, before claiming the canvas', async () => {
    const { create, canvas, context, device } = setupRenderer()
    device.popErrorScope.mockImplementation(async () => {
      expect(canvas.getContext).not.toHaveBeenCalled()
      return null
    })
    const renderer = await create()
    expect(renderer.kind).toBe('webgpu')
    expect(renderer.filters).toEqual(['none', 'crt'])
    expect(device.pushErrorScope.mock.calls).toEqual([['validation'], ['validation']])
    expect(device.popErrorScope).toHaveBeenCalledTimes(2)
    expect(canvas.getContext.mock.calls).toEqual([['webgpu']])
    expect(context.configure).toHaveBeenCalledWith({ device, format: 'bgra8unorm', alphaMode: 'opaque' })
  })

  it.each(['pipeline rejection', 'validation error'])(
    'keeps WebGPU and the plain picture when CRT fails through a %s',
    async (failure) => {
      const { create, device, canvas, queue, pass, plainPipeline } = setupRenderer()
      const error = new Error('CRT unavailable')
      if (failure === 'pipeline rejection') {
        device.createRenderPipelineAsync.mockReset()
          .mockResolvedValueOnce(plainPipeline)
          .mockRejectedValueOnce(error)
      } else {
        device.popErrorScope.mockResolvedValueOnce(null).mockResolvedValueOnce(error)
      }
      const renderer = await create()
      expect(renderer.kind).toBe('webgpu')
      expect(renderer.filters).toEqual(['none'])
      expect(device.popErrorScope).toHaveBeenCalledTimes(2)
      expect(console.error).toHaveBeenCalledWith("Display filter 'crt' is unavailable on this GPU:", error)
      expect(console.warn).not.toHaveBeenCalled()

      renderer.setDisplay(CRT, 1024)
      expect([canvas.width, canvas.height]).toEqual([256, 240])
      expect(pass.setPipeline).toHaveBeenLastCalledWith(plainPipeline)
      expect(queue.submit).toHaveBeenCalledTimes(1)
    },
  )

  it.each(['plain pipeline', 'shared bind group validation'])(
    'falls back before claiming the WebGPU canvas when %s fails',
    async (failure) => {
      const { create, canvas, device } = setupRenderer()
      const error = new Error('invalid GPU setup')
      if (failure === 'plain pipeline') device.createRenderPipelineAsync.mockReset().mockRejectedValueOnce(error)
      else device.popErrorScope.mockResolvedValueOnce(error)

      const renderer = await create()
      expect(renderer.kind).toBe('canvas2d')
      expect(renderer.filters).toEqual(['none'])
      expect(canvas.getContext.mock.calls).toEqual([['2d']])
      expect(console.warn).toHaveBeenCalledWith(
        'WebGPU renderer unavailable, falling back to Canvas 2D:', expect.any(Error),
      )
      if (failure === 'shared bind group validation') {
        expect(String(vi.mocked(console.warn).mock.calls[0][1])).toContain('invalid GPU setup')
      }
    },
  )

  it('ignores stored CRT settings on Canvas 2D without changing its backing size or painting', async () => {
    const { canvas, canvas2d, gpu, queue } = setupRenderer()
    const renderer = await createRenderer(canvas as unknown as OffscreenCanvas, 256, 240, 'canvas2d')
    renderer.setDisplay(CRT, 2048)
    expect(renderer.filters).toEqual(['none'])
    expect([canvas.width, canvas.height]).toEqual([256, 240])
    expect(canvas2d.putImageData).not.toHaveBeenCalled()
    expect(queue.submit).not.toHaveBeenCalled()
    expect(gpu.requestAdapter).not.toHaveBeenCalled()
  })

  it.each([
    { width: null, size: [1024, 960] },
    { width: 919.6, size: [920, 863] },
    { width: 100, size: [256, 240] },
    { width: 10000, size: [4096, 3840] },
  ])('sizes CRT at $width device pixels and uploads matching uniforms', async ({ width, size }) => {
    const { create, canvas, queue, uniform, pass, crtPipeline, bindGroup } = setupRenderer()
    const renderer = await create()
    renderer.setDisplay(CRT, width)
    expect([canvas.width, canvas.height]).toEqual(size)
    expect(queue.writeBuffer).toHaveBeenCalledWith(
      uniform, 0, new Float32Array([...size, 256, 240, 0, 1, 0, 1]),
    )
    expect(pass.setPipeline).toHaveBeenLastCalledWith(crtPipeline)
    expect(pass.setBindGroup).toHaveBeenLastCalledWith(0, bindGroup)
    expect(pass.draw).toHaveBeenLastCalledWith(3)
    expect(queue.submit).toHaveBeenCalledTimes(1)
    expect(queue.writeTexture).not.toHaveBeenCalled()
  })

  it('repaints the last frame on option, size, and filter changes without uploading or mutating it', async () => {
    const { create, canvas, queue, pass, texture, uniform, plainPipeline } = setupRenderer()
    const renderer = await create()
    const frame = new Uint8ClampedArray(256 * 240 * 4).fill(127)
    const original = frame.slice()
    renderer.draw(frame)
    renderer.setDisplay(CRT, 1024)
    renderer.setDisplay({ ...CRT, crt: { ...CRT.crt, scanlines: true } }, 1024)
    expect(queue.writeBuffer).toHaveBeenLastCalledWith(
      uniform, 0, new Float32Array([1024, 960, 256, 240, 1, 1, 0, 1]),
    )
    renderer.setDisplay(CRT, 1536)
    expect(queue.writeBuffer).toHaveBeenLastCalledWith(
      uniform, 0, new Float32Array([1536, 1440, 256, 240, 0, 1, 0, 1]),
    )
    renderer.setDisplay(DEFAULT_DISPLAY_FILTER, 1536)

    expect(queue.writeTexture).toHaveBeenCalledExactlyOnceWith(
      { texture }, frame, { bytesPerRow: 1024, rowsPerImage: 240 }, { width: 256, height: 240 },
    )
    expect(frame).toEqual(original)
    expect(queue.submit).toHaveBeenCalledTimes(5)
    expect(queue.writeBuffer).toHaveBeenCalledTimes(4)
    expect(queue.writeBuffer).toHaveBeenLastCalledWith(
      uniform, 0, new Float32Array([256, 240, 256, 240, 1, 1, 1, 1]),
    )
    expect([canvas.width, canvas.height]).toEqual([256, 240])
    expect(pass.setPipeline).toHaveBeenLastCalledWith(plainPipeline)
  })

  it('continues uploading source-resolution frames while the filtered canvas is larger', async () => {
    const { create, queue, texture, pass, crtPipeline } = setupRenderer()
    const renderer = await create()
    renderer.setDisplay(CRT, 2048)
    const frame = new Uint8ClampedArray(256 * 240 * 4)
    renderer.draw(frame)
    expect(queue.writeTexture).toHaveBeenCalledWith(
      { texture }, frame, { bytesPerRow: 1024, rowsPerImage: 240 }, { width: 256, height: 240 },
    )
    expect(pass.setPipeline).toHaveBeenLastCalledWith(crtPipeline)
    expect(queue.submit).toHaveBeenCalledTimes(2)
  })

  it('logs uncaptured draw errors without claiming another canvas context', async () => {
    const { create, device, canvas } = setupRenderer()
    await create()
    expect(device.onuncapturederror).toEqual(expect.any(Function))
    device.onuncapturederror?.({ error: { message: 'draw validation failed' } })
    expect(console.error).toHaveBeenCalledWith('WebGPU error:', 'draw validation failed')
    expect(canvas.getContext.mock.calls).toEqual([['webgpu']])
  })
})
