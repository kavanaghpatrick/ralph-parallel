// EMA smoothing compute shader -- sequential exponential moving average
// Ring buffer bind group (shared contract across all compute shaders)

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

struct SmoothParams {
  alpha: f32,
  count: u32,
  _pad1: u32,
  _pad2: u32,
}

@group(1) @binding(0) var<uniform> params: SmoothParams;
@group(1) @binding(1) var<storage, read_write> output: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  // EMA is sequential -- only thread 0 executes
  if (gid.x != 0u) {
    return;
  }

  let count = params.count;
  if (count == 0u) {
    return;
  }

  let alpha = params.alpha;
  let oneMinusAlpha = 1.0 - alpha;

  // Initialize first value
  output[0] = ringData[ringIndex(0u, ringMeta)];

  // Sequential EMA: output[i] = alpha * raw[i] + (1 - alpha) * output[i-1]
  for (var i = 1u; i < count; i = i + 1u) {
    let idx = ringIndex(i, ringMeta);
    let raw = ringData[idx];
    output[i] = alpha * raw + oneMinusAlpha * output[i - 1u];
  }
}
