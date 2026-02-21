// Heatmap render shader
// Full-screen quad with color ramp: blue (low) -> yellow (mid) -> red (high)

struct HeatmapUniforms {
  gridSize: u32,
  maxCount: u32,
  _pad1: u32,
  _pad2: u32,
}

@group(0) @binding(0) var<storage, read> bins: array<u32>;
@group(0) @binding(1) var<uniform> uniforms: HeatmapUniforms;

struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VSOut {
  // Full-screen quad: 6 vertices -> 2 triangles
  var positions = array<vec2f, 6>(
    vec2f(-1.0, -1.0),
    vec2f( 1.0, -1.0),
    vec2f(-1.0,  1.0),
    vec2f(-1.0,  1.0),
    vec2f( 1.0, -1.0),
    vec2f( 1.0,  1.0),
  );
  var uvs = array<vec2f, 6>(
    vec2f(0.0, 1.0),
    vec2f(1.0, 1.0),
    vec2f(0.0, 0.0),
    vec2f(0.0, 0.0),
    vec2f(1.0, 1.0),
    vec2f(1.0, 0.0),
  );

  var out: VSOut;
  out.pos = vec4f(positions[vid], 0.0, 1.0);
  out.uv = uvs[vid];
  return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
  let cellX = min(u32(in.uv.x * f32(uniforms.gridSize)), uniforms.gridSize - 1u);
  let cellY = min(u32(in.uv.y * f32(uniforms.gridSize)), uniforms.gridSize - 1u);
  let count = bins[cellY * uniforms.gridSize + cellX];
  let t = f32(count) / f32(max(uniforms.maxCount, 1u));

  // Color ramp: blue (0) -> yellow (0.5) -> red (1)
  let r = smoothstep(0.0, 0.5, t);
  let g = smoothstep(0.0, 0.5, t) - smoothstep(0.5, 1.0, t);
  let b = 1.0 - smoothstep(0.0, 0.5, t);
  return vec4f(r, g, b, 1.0);
}
