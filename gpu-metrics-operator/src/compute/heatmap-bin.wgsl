// Heatmap binning compute shader
// Bins 2D (x, y) points from ring buffer into a gridSize x gridSize grid

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

struct HeatmapParams {
  gridSize: u32,
  _pad1: u32,
  _pad2: u32,
  _pad3: u32,
}

@group(1) @binding(0) var<uniform> params: HeatmapParams;
@group(1) @binding(1) var<storage, read_write> bins: array<atomic<u32>>;

@compute @workgroup_size(64)
fn clear(@builtin(global_invocation_id) gid: vec3u) {
  if (gid.x < params.gridSize * params.gridSize) {
    atomicStore(&bins[gid.x], 0u);
  }
}

@compute @workgroup_size(64)
fn bin(@builtin(global_invocation_id) gid: vec3u) {
  if (gid.x >= ringMeta.count) { return; }
  let idx = ringIndex(gid.x, ringMeta);
  let x = ringData[idx];
  let y = ringData[idx + 1u];
  let cellX = min(u32(x * f32(params.gridSize)), params.gridSize - 1u);
  let cellY = min(u32(y * f32(params.gridSize)), params.gridSize - 1u);
  atomicAdd(&bins[cellY * params.gridSize + cellX], 1u);
}
