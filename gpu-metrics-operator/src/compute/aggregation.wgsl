// Aggregation compute shader -- min/max/sum reduction over ring buffer data
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

struct AggResult {
  min_val: f32,
  max_val: f32,
  sum_val: f32,
  count: u32,
}

@group(1) @binding(0) var<storage, read_write> result: AggResult;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  // POC: thread 0 does sequential reduction for simplicity
  if (gid.x != 0u) {
    return;
  }

  let count = ringMeta.count;
  if (count == 0u) {
    result.min_val = 0.0;
    result.max_val = 0.0;
    result.sum_val = 0.0;
    result.count = 0u;
    return;
  }

  var min_v = ringData[ringIndex(0u, ringMeta)];
  var max_v = min_v;
  var sum_v = min_v;

  for (var i = 1u; i < count; i = i + 1u) {
    let idx = ringIndex(i, ringMeta);
    let v = ringData[idx];
    min_v = min(min_v, v);
    max_v = max(max_v, v);
    sum_v = sum_v + v;
  }

  result.min_val = min_v;
  result.max_val = max_v;
  result.sum_val = sum_v;
  result.count = count;
}
