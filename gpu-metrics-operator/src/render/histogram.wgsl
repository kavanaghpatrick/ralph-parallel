// Histogram render shader -- instanced bar chart

struct HistUniforms {
  numBins: u32,
  maxCount: u32,
  _pad1: u32,
  _pad2: u32,
}

@group(0) @binding(0) var<storage, read> bins: array<u32>;
@group(0) @binding(1) var<uniform> uniforms: HistUniforms;

@vertex
fn vs_main(
  @builtin(vertex_index) vid: u32,
  @builtin(instance_index) iid: u32,
) -> @builtin(position) vec4f {
  // 6 vertices per bar (quad), instanced by numBins
  let binWidth = 2.0 / f32(uniforms.numBins);
  let count = bins[iid];
  let height = f32(count) / f32(max(uniforms.maxCount, 1u)) * 2.0;

  let left = -1.0 + f32(iid) * binWidth;
  let right = left + binWidth * 0.9;
  let bottom = -1.0;
  let top = bottom + height;

  // vid: 0=BL, 1=BR, 2=TL, 3=TL, 4=BR, 5=TR
  var x: f32;
  var y: f32;
  switch vid % 6u {
    case 0u: { x = left;  y = bottom; }
    case 1u: { x = right; y = bottom; }
    case 2u: { x = left;  y = top;    }
    case 3u: { x = left;  y = top;    }
    case 4u: { x = right; y = bottom; }
    case 5u: { x = right; y = top;    }
    default: { x = 0.0;   y = 0.0;    }
  }

  return vec4f(x, y, 0.0, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4f {
  return vec4f(0.35, 0.65, 0.95, 1.0);
}
