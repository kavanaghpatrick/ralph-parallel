// Line chart render shader -- thick line segments via triangle-list quads

struct LineUniforms {
  pointCount: u32,
  thickness: f32,
  minVal: f32,
  maxVal: f32,
}

@group(0) @binding(0) var<storage, read> smoothed: array<f32>;
@group(0) @binding(1) var<uniform> uniforms: LineUniforms;

struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) color: vec3f,
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VSOut {
  // 6 vertices per segment (2 triangles = thick line quad)
  let segIdx = vid / 6u;
  let corner = vid % 6u;

  let pointCount = uniforms.pointCount;
  let range = uniforms.maxVal - uniforms.minVal;
  let safeRange = select(range, 1.0, range < 0.0001);

  // Read two endpoints of this segment
  let v0 = smoothed[segIdx];
  let v1 = smoothed[segIdx + 1u];

  // Normalize Y to [0, 1] using min/max, then map to NDC [-1, 1]
  let y0 = ((v0 - uniforms.minVal) / safeRange) * 2.0 - 1.0;
  let y1 = ((v1 - uniforms.minVal) / safeRange) * 2.0 - 1.0;

  // X spans [-1, 1] across pointCount
  let step = 2.0 / f32(pointCount - 1u);
  let x0 = -1.0 + f32(segIdx) * step;
  let x1 = -1.0 + f32(segIdx + 1u) * step;

  // Direction and perpendicular for thickness
  let dx = x1 - x0;
  let dy = y1 - y0;
  let len = sqrt(dx * dx + dy * dy);
  let safeLen = select(len, 1.0, len < 0.00001);
  // Perpendicular normalized, scaled by thickness in NDC
  let px = -dy / safeLen * uniforms.thickness * 0.001;
  let py = dx / safeLen * uniforms.thickness * 0.001;

  // Quad corners: BL(0), BR(1), TL(2), TL(3), BR(4), TR(5)
  // "Bottom" = offset in -perpendicular, "Top" = offset in +perpendicular
  // "Left" = segment start (x0,y0), "Right" = segment end (x1,y1)
  var pos: vec2f;
  switch corner {
    case 0u: { pos = vec2f(x0 - px, y0 - py); } // BL
    case 1u: { pos = vec2f(x1 - px, y1 - py); } // BR
    case 2u: { pos = vec2f(x0 + px, y0 + py); } // TL
    case 3u: { pos = vec2f(x0 + px, y0 + py); } // TL
    case 4u: { pos = vec2f(x1 - px, y1 - py); } // BR
    case 5u: { pos = vec2f(x1 + px, y1 + py); } // TR
    default: { pos = vec2f(0.0, 0.0); }
  }

  // Green-ish gradient based on Y position
  let t = (pos.y + 1.0) * 0.5;
  let color = vec3f(0.2, 0.7 + t * 0.2, 0.4);

  var out: VSOut;
  out.pos = vec4f(pos, 0.0, 1.0);
  out.color = color;
  return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
  return vec4f(in.color, 1.0);
}
