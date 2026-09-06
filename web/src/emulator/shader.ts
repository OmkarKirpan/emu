/**
 * The WGSL the WebGPU renderer draws with: one oversized triangle covering
 * the whole clip volume, textured with the NES framebuffer. Cheaper than
 * two triangles for a quad and needs no vertex buffer at all -- the
 * positions come from the vertex index.
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
`

/** Entry point names and binding slots `renderer.ts`'s pipeline and bind
 * group hard-code. Exported so `shader.test.ts` asserts the shader and the
 * pipeline agree, rather than the two drifting into a mismatch that only a
 * GPU-having machine would ever notice. */
export const SHADER_INTERFACE = {
  vertexEntryPoint: 'vs',
  fragmentEntryPoint: 'fs',
  samplerBinding: 0,
  textureBinding: 1,
} as const
