// Histogram binning compute shader
// Ring buffer contract: see design.md "Shared: Ring Buffer Bind Group (Group 0)"

struct RingMeta {
  head: u32,
  count: u32,
  capacity: u32,
  channelCount: u32,
}

@group(0) @binding(0) var<storage, read> ringData: array<f32>;
@group(0) @binding(1) var<uniform> ringMeta: RingMeta;

fn ringIndex(i: u32, meta: RingMeta) -> u32 {
  let start = (meta.head - meta.count + meta.capacity) % meta.capacity;
  return ((start + i) % meta.capacity) * meta.channelCount;
}

struct HistParams {
  numBins: u32,
  _pad1: u32,
  _pad2: u32,
  _pad3: u32,
}

@group(1) @binding(0) var<uniform> params: HistParams;
@group(1) @binding(1) var<storage, read_write> bins: array<atomic<u32>>;

@compute @workgroup_size(64)
fn clear(@builtin(global_invocation_id) gid: vec3u) {
  if (gid.x < params.numBins) {
    atomicStore(&bins[gid.x], 0u);
  }
}

@compute @workgroup_size(64)
fn bin(@builtin(global_invocation_id) gid: vec3u) {
  if (gid.x >= ringMeta.count) { return; }
  let idx = ringIndex(gid.x, ringMeta);
  let v = clamp(ringData[idx], 0.0, 1.0);
  let b = min(u32(v * f32(params.numBins)), params.numBins - 1u);
  atomicAdd(&bins[b], 1u);
}
