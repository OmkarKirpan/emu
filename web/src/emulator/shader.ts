import type { CrtOptions, DisplayFilterKind } from './displayFilter'

/**
 * The WGSL the WebGPU renderer draws with: one oversized triangle covering
 * the whole clip volume, textured with the NES framebuffer. Cheaper than
 * two triangles for a quad and needs no vertex buffer at all -- the
 * positions come from the vertex index.
 *
 * One fragment entry point per display filter (`displayFilter.ts`), all
 * sharing the vertex stage and one bind group: `fs` is the plain picture,
 * `fs_crt` the CRT filter. `renderer.ts` builds a pipeline per entry point
 * and switches between them, so the unfiltered path is exactly the shader
 * it always was rather than a CRT shader with everything turned off.
 *
 * Kept in its own module, apart from `renderer.ts`, for two reasons. It's
 * plain text with no WebGPU types in it, so it can be imported by
 * `shader.test.ts` (which runs in the app/`DOM` TypeScript project and
 * under jsdom) without dragging `renderer.ts`'s `GPUDevice`-and-friends
 * into a project that has no `@webgpu/types`. And that test is the only
 * automated check this shader can get: CI has no GPU, so nothing there can
 * ever run it -- parsing it and asserting its interface is the substitute.
 */
export const FRAME_SHADER = /* wgsl */ `
struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
};

@vertex
fn vs(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var positions = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f( 3.0, -1.0),
    vec2f(-1.0,  3.0),
  );
  let pos = positions[vertexIndex];
  var out: VertexOutput;
  out.position = vec4f(pos, 0.0, 1.0);
  // Clip space is y-up around a centred origin; texture space is y-down
  // from the top-left, and the framebuffer's first row is the top of the
  // NES frame -- hence the flip on y. Only the [-1,1] part of this
  // oversized triangle is rasterized, so uv stays within 0..1 on screen.
  out.uv = vec2f((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
  return out;
}

@group(0) @binding(0) var frameSampler: sampler;
@group(0) @binding(1) var frameTexture: texture_2d<f32>;

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4f {
  return textureSample(frameTexture, frameSampler, in.uv);
}

// ---- CRT filter --------------------------------------------------------
//
// Runs at the canvas's on-screen resolution, not the framebuffer's (see
// displayFilter.ts's filteredCanvasSize). Each effect is scaled by its own
// 0..1 strength, so a switched-off effect costs a multiply, not a branch.
// textureSampleLevel throughout rather than textureSample: the sampling
// coordinates are warped per pixel, and the explicit level sidesteps
// WGSL's uniform-control-flow rule for implicit-derivative sampling.

struct CrtParams {
  outputSize: vec2f,
  sourceSize: vec2f,
  scanlines: f32,
  curvature: f32,
  chromaticAberration: f32,
  vignette: f32,
};

@group(0) @binding(2) var<uniform> crt: CrtParams;
@group(0) @binding(3) var smoothSampler: sampler;

// Barrel distortion: bows the flat picture out into a convex tube face.
// Each axis is stretched in proportion to the square of the other axis's
// distance from centre, so the edges curve and the corners fall off the
// tube entirely.
fn crtWarp(uv: vec2f) -> vec2f {
  let centered = uv * 2.0 - 1.0;
  let bulge = vec2f(1.0 + centered.y * centered.y / 20.0, 1.0 + centered.x * centered.x / 14.0);
  return centered * mix(vec2f(1.0), bulge, crt.curvature) * 0.5 + 0.5;
}

// Sharp-bilinear: nearest-neighbour across the middle of each NES pixel,
// a linear blend only over the last device pixel or so at its edges.
// Nearest alone would stair-step once curvature and fringing move the
// picture by fractions of a pixel; bilinear alone would blur the pixel art.
fn sampleSharp(uv: vec2f) -> vec3f {
  let texel = uv * crt.sourceSize;
  let scale = max(crt.outputSize / crt.sourceSize, vec2f(1.0));
  let region = 0.5 - 0.5 / scale;
  let fromCenter = fract(texel) - 0.5;
  let sharpened = floor(texel) + (fromCenter - clamp(fromCenter, -region, region)) * scale + 0.5;
  return textureSampleLevel(frameTexture, smoothSampler, sharpened / crt.sourceSize, 0.0).rgb;
}

@fragment
fn fs_crt(in: VertexOutput) -> @location(0) vec4f {
  let uv = crtWarp(in.uv);

  // Chromatic aberration: red and blue land slightly off green, like a tube
  // whose three electron beams don't quite converge -- by a hair at the
  // centre, more towards the edges.
  let fringe = (vec2f(0.5 / crt.sourceSize.x, 0.0) + (uv - 0.5) * 0.006) * crt.chromaticAberration;
  var color = vec3f(sampleSharp(uv + fringe).r, sampleSharp(uv).g, sampleSharp(uv - fringe).b);

  // Scanlines: each NES row drawn as a beam, brightest along its centre and
  // dimming into the gap above and below it. Divided back up by the
  // average darkening, so the picture gains texture rather than just
  // getting dimmer. Faded out below ~3 device pixels per row, where there
  // aren't enough pixels to draw a beam and the pattern would only alias.
  let beam = 0.5 + 0.5 * cos(6.2831853 * (fract(uv.y * crt.sourceSize.y) - 0.5));
  let depth = 0.45 * crt.scanlines * smoothstep(2.0, 3.0, crt.outputSize.y / crt.sourceSize.y);
  color *= (1.0 - depth * (1.0 - beam)) / (1.0 - 0.5 * depth);

  // Vignette: the tube's face darkening towards its edges and corners.
  let edges = uv * (1.0 - uv);
  let falloff = pow(clamp(edges.x * edges.y * 16.0, 0.0, 1.0), 0.3);
  color *= mix(1.0, falloff, crt.vignette);

  // Off the edge of the (possibly bowed) tube face: black. Faded across one
  // device pixel, so a curved edge doesn't stair-step -- and centred on the
  // edge itself, so with curvature off the outermost pixels stay untouched.
  let halfPixel = 0.5 / crt.outputSize;
  let inside = smoothstep(-halfPixel, halfPixel, uv) * smoothstep(-halfPixel, halfPixel, 1.0 - uv);
  return vec4f(color * inside.x * inside.y, 1.0);
}
`

/** Entry point names and binding slots `renderer.ts`'s pipelines and bind
 * group hard-code. Exported so `shader.test.ts` asserts the shader and the
 * pipelines agree, rather than the two drifting into a mismatch that only a
 * GPU-having machine would ever notice. `fragmentEntryPoints` is checked
 * against `DISPLAY_FILTERS`, so a new filter kind without a shader is a type
 * error here. */
export const SHADER_INTERFACE = {
  vertexEntryPoint: 'vs',
  fragmentEntryPoints: { none: 'fs', crt: 'fs_crt' } satisfies Record<DisplayFilterKind, string>,
  samplerBinding: 0,
  textureBinding: 1,
  crtParamsBinding: 2,
  smoothSamplerBinding: 3,
} as const

/** Float index of each `CrtParams` field in the buffer `packCrtParams`
 * writes. `shader.test.ts` checks every one against the WGSL struct's real
 * member offsets. */
export const CRT_PARAMS_LAYOUT = {
  outputSize: 0,
  sourceSize: 2,
  scanlines: 4,
  curvature: 5,
  chromaticAberration: 6,
  vignette: 7,
} as const

export const CRT_PARAMS_FLOATS = 8

/** The `CrtParams` uniform for one canvas size and set of options. Each
 * option becomes a 0/1 strength (see `CrtOptions`). */
export function packCrtParams(
  options: CrtOptions,
  outputWidth: number,
  outputHeight: number,
  sourceWidth: number,
  sourceHeight: number,
): Float32Array<ArrayBuffer> {
  const params = new Float32Array(CRT_PARAMS_FLOATS)
  params[CRT_PARAMS_LAYOUT.outputSize] = outputWidth
  params[CRT_PARAMS_LAYOUT.outputSize + 1] = outputHeight
  params[CRT_PARAMS_LAYOUT.sourceSize] = sourceWidth
  params[CRT_PARAMS_LAYOUT.sourceSize + 1] = sourceHeight
  params[CRT_PARAMS_LAYOUT.scanlines] = options.scanlines ? 1 : 0
  params[CRT_PARAMS_LAYOUT.curvature] = options.curvature ? 1 : 0
  params[CRT_PARAMS_LAYOUT.chromaticAberration] = options.chromaticAberration ? 1 : 0
  params[CRT_PARAMS_LAYOUT.vignette] = options.vignette ? 1 : 0
  return params
}
