---
spec: gpu-metrics-operator
phase: tasks
created: 2026-02-21
---

# Tasks: GPU Metrics Operator

## Phase 1: Make It Work (POC) -- Parallel Groups 1-4

Groups 1-4 execute in parallel. Zero file overlap between groups. Each group's tasks are sequential within the group.

### Group 1: Infrastructure [P]

**Files owned** (8): `gpu-metrics-operator/package.json`, `gpu-metrics-operator/tsconfig.json`, `gpu-metrics-operator/vite.config.ts`, `gpu-metrics-operator/index.html`, `gpu-metrics-operator/src/types.ts`, `gpu-metrics-operator/src/gpu/device.ts`, `gpu-metrics-operator/src/gpu/ring-buffer.ts`, `gpu-metrics-operator/src/gpu/buffers.ts`

- [x] 1.1 [P] Scaffold project: package.json, tsconfig, vite config
  - **Do**:
    1. Create `gpu-metrics-operator/` directory
    2. Create `package.json` with dependencies: `vite`, `vite-plugin-wgsl`, `typescript`, `@webgpu/types`. Scripts: `"dev": "vite"`, `"build": "vite build"`, `"preview": "vite preview"`, `"typecheck": "tsc --noEmit"`
    3. Create `tsconfig.json`: target ESNext, module ESNext, moduleResolution bundler, lib ["ESNext", "DOM", "DOM.Iterable"], types ["@webgpu/types"], strict true, skipLibCheck true, outDir dist
    4. Create `vite.config.ts`: import wgsl from vite-plugin-wgsl, export default { plugins: [wgsl()] }
    5. Run `cd gpu-metrics-operator && npm install`
  - **Files**: `gpu-metrics-operator/package.json`, `gpu-metrics-operator/tsconfig.json`, `gpu-metrics-operator/vite.config.ts`
  - **Done when**: `cd gpu-metrics-operator && npx tsc --noEmit` exits 0 (no source files yet is OK), `node -e "require('./package.json')"` works
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && ls package.json tsconfig.json vite.config.ts && node -e "const p=require('./package.json'); console.log(p.dependencies['vite-plugin-wgsl'] ? 'OK' : 'MISSING')"`
  - **Commit**: `feat(gpu-metrics): scaffold project with vite + wgsl plugin`
  - _Requirements: AC-9.1 through AC-9.5, FR-12_
  - _Design: Group 1 Infrastructure_

- [x] 1.2 [P] Create index.html with CSS grid layout and 3 canvases
  - **Do**:
    1. Create `index.html` at project root (gpu-metrics-operator/)
    2. CSS grid: 1 row header, 2-row body. Top row = line chart (full width). Bottom row = heatmap (left) + histogram (right)
    3. Each panel: `<canvas id="line-canvas">`, `<canvas id="heatmap-canvas">`, `<canvas id="histogram-canvas">`
    4. HTML overlay divs for chart titles: "Time Series (EMA Smoothed)", "2D Density Heatmap", "Value Distribution"
    5. Fallback container `<div id="fallback">` hidden by default
    6. `<script type="module" src="/src/main.ts"></script>` entry point
    7. Min viewport 1280x720, dark background (#1a1a2e or similar)
  - **Files**: `gpu-metrics-operator/index.html`
  - **Done when**: HTML validates, contains 3 canvas elements with correct IDs
  - **Verify**: `grep -c '<canvas' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/index.html | grep 3`
  - **Commit**: `feat(gpu-metrics): add dashboard HTML layout with 3 canvases`
  - _Requirements: AC-8.1, AC-8.2, AC-8.3, AC-8.4_
  - _Design: Component 9 (Orchestrator), index.html layout_

- [x] 1.3 [P] Implement shared types and constants
  - **Do**:
    1. Create `src/types.ts`
    2. Add WGSL module declaration: `declare module '*.wgsl' { const shader: string; export default shader; }`
    3. Add `Chart` interface: `frame(encoder: GPUCommandEncoder): boolean`, `markDirty(): void`, `destroy(): void`
    4. Add `ChartContext` interface: `device: GPUDevice`, `canvas: HTMLCanvasElement`, `gpuContext: GPUCanvasContext`, `format: GPUTextureFormat`
    5. Add constants: `WORKGROUP_SIZE = 64`, `DEFAULT_RING_CAPACITY = 4096`, `DEFAULT_HEATMAP_GRID_SIZE = 32`, `DEFAULT_HISTOGRAM_BINS = 32`, `DEFAULT_DATA_INTERVAL_MS = 500`, `DEFAULT_BATCH_SIZE = 64`, `DEFAULT_EMA_ALPHA = 0.1`, `DEFAULT_LINE_THICKNESS = 2.0`
  - **Files**: `gpu-metrics-operator/src/types.ts`
  - **Done when**: File exports all interfaces and constants per design spec
  - **Verify**: `grep -c 'export' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/types.ts | xargs test 8 -le`
  - **Commit**: `feat(gpu-metrics): add shared types, interfaces, and constants`
  - _Requirements: AC-4.4, AC-9.5, NFR-4, NFR-5_
  - _Design: Component 4 (Shared Types)_

- [x] 1.4 [P] Implement GPU device initialization and fallback
  - **Do**:
    1. Create `src/gpu/device.ts`
    2. `initGPU()`: check `navigator.gpu`, call `requestAdapter()`, call `requestDevice()`, return GPUDevice or null. Log failure reason.
    3. `showFallback(container, reason)`: set container innerHTML to styled fallback message "WebGPU is not supported in this browser" with reason
    4. Both functions exported
  - **Files**: `gpu-metrics-operator/src/gpu/device.ts`
  - **Done when**: Exports `initGPU` and `showFallback` matching design signatures
  - **Verify**: `grep 'export.*function initGPU' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/device.ts && grep 'export.*function showFallback' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/device.ts`
  - **Commit**: `feat(gpu-metrics): implement GPU device init with fallback`
  - _Requirements: AC-1.1 through AC-1.4, NFR-3_
  - _Design: Component 1 (GPU Device)_

- [x] 1.5 [P] Implement ring buffer factory
  - **Do**:
    1. Create `src/gpu/ring-buffer.ts`
    2. Export `RingBufferConfig` and `RingBuffer` interfaces matching design
    3. Implement `createRingBuffer(config)`:
       - Create storage buffer: `size = capacity * channelCount * 4`, usage `STORAGE | COPY_DST`
       - Create meta uniform: 16 bytes `[head, count, capacity, channelCount]`, usage `UNIFORM | COPY_DST`
       - Create bind group layout: binding(0) = storage read, binding(1) = uniform
       - Create bind group with both buffers
       - Implement `push(data)`: write data at head position, advance head with wrap, update meta via writeBuffer
       - Track `head`, `count`, `capacity` as CPU-side state
    4. Validate capacity is power of 2 in factory
  - **Files**: `gpu-metrics-operator/src/gpu/ring-buffer.ts`
  - **Done when**: Exports `createRingBuffer`, `RingBuffer`, `RingBufferConfig`
  - **Verify**: `grep 'export.*function createRingBuffer' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/ring-buffer.ts && grep 'export.*interface RingBuffer' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/ring-buffer.ts`
  - **Commit**: `feat(gpu-metrics): implement GPU ring buffer with circular push`
  - _Requirements: AC-3.1 through AC-3.5, NFR-5, NFR-7_
  - _Design: Component 2 (Ring Buffer)_

- [x] 1.6 [P] Implement ping-pong buffer manager and buffer utilities
  - **Do**:
    1. Create `src/gpu/buffers.ts`
    2. Export `PingPongConfig` and `PingPongBuffers` interfaces
    3. Implement `createPingPong(config)`:
       - Create 2 buffers with usage `STORAGE | VERTEX`
       - Return object with writeBuffer, readBuffer, swap()
       - swap() exchanges the references
    4. Implement `createBuffer(device, size, usage, label?)`: thin wrapper over `device.createBuffer`
  - **Files**: `gpu-metrics-operator/src/gpu/buffers.ts`
  - **Done when**: Exports `createPingPong`, `createBuffer`, `PingPongBuffers`, `PingPongConfig`
  - **Verify**: `grep 'export.*function createPingPong' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/buffers.ts && grep 'export.*function createBuffer' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/buffers.ts`
  - **Commit**: `feat(gpu-metrics): implement ping-pong double buffering`
  - _Requirements: AC-5.5, FR-11, AC-4.5, NFR-6_
  - _Design: Component 3 (Ping-Pong Buffer Manager)_

- [x] 1.7 [P] [VERIFY] Group 1 quality checkpoint: typecheck
  - **Do**: Run typecheck on the infrastructure files
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit`
  - **Done when**: Zero type errors
  - **Commit**: `chore(gpu-metrics): pass group 1 quality checkpoint` (only if fixes needed)

---

### Group 2: Line Chart [P]

**Files owned** (4): `gpu-metrics-operator/src/compute/aggregation.wgsl`, `gpu-metrics-operator/src/compute/smoothing.wgsl`, `gpu-metrics-operator/src/render/line-chart.ts`, `gpu-metrics-operator/src/render/line-chart.wgsl`

- [x] 1.8 [P] Implement aggregation compute shader
  - **Do**:
    1. Create `src/compute/aggregation.wgsl`
    2. Declare `RingMeta` struct and ring buffer bindings at group(0)
    3. Implement `ringIndex()` helper function
    4. Declare `AggResult` struct at group(1) binding(0): `{min_val: f32, max_val: f32, sum_val: f32, count: u32}`
    5. Entry point `main` with `@workgroup_size(64)`:
       - Thread 0 initializes result: min_val = 0x7F7FFFFF (FLT_MAX as bits), max_val = 0xFF7FFFFF, sum_val = 0.0, count = ringMeta.count
       - workgroupBarrier()
       - Each thread processes indices [gid.x, gid.x + workgroupSize, ...] up to count
       - Use bitcast<u32> for atomicMin/atomicMax on positive floats
       - atomicAdd for sum (also via bitcast trick or accumulate per-thread then reduce)
    6. Note: for simplicity in POC, thread 0 can do sequential reduction. Parallel atomic version is stretch.
  - **Files**: `gpu-metrics-operator/src/compute/aggregation.wgsl`
  - **Done when**: Valid WGSL with RingMeta struct, AggResult output, main entry point
  - **Verify**: `grep '@compute @workgroup_size(64)' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/aggregation.wgsl && grep 'AggResult' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/aggregation.wgsl`
  - **Commit**: `feat(gpu-metrics): implement aggregation compute shader`
  - _Requirements: AC-4.1, AC-4.3, AC-4.4_
  - _Design: WGSL Contract - aggregation.wgsl_

- [x] 1.9 [P] Implement EMA smoothing compute shader
  - **Do**:
    1. Create `src/compute/smoothing.wgsl`
    2. Declare RingMeta struct and ring buffer bindings at group(0)
    3. Implement ringIndex() helper
    4. Declare SmoothParams at group(1) binding(0): `{alpha: f32, count: u32, _pad1: u32, _pad2: u32}`
    5. Declare output array at group(1) binding(1): `var<storage, read_write> output: array<f32>`
    6. Entry point `main` with `@workgroup_size(64)`:
       - Only thread 0 runs (gid.x != 0 returns)
       - output[0] = ringData[ringIndex(0)]
       - Loop i = 1 to count-1: output[i] = alpha * ringData[ringIndex(i)] + (1-alpha) * output[i-1]
  - **Files**: `gpu-metrics-operator/src/compute/smoothing.wgsl`
  - **Done when**: Valid WGSL with sequential EMA, single-thread execution
  - **Verify**: `grep '@compute @workgroup_size(64)' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/smoothing.wgsl && grep 'SmoothParams' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/smoothing.wgsl`
  - **Commit**: `feat(gpu-metrics): implement EMA smoothing compute shader`
  - _Requirements: AC-4.2, AC-4.5_
  - _Design: WGSL Contract - smoothing.wgsl_

- [x] 1.10 [P] Implement line chart render shader
  - **Do**:
    1. Create `src/render/line-chart.wgsl`
    2. Declare `LineUniforms` struct at group(0) binding(1): `{pointCount: u32, thickness: f32, minVal: f32, maxVal: f32}`
    3. Declare smoothed data at group(0) binding(0): `var<storage, read> smoothed: array<f32>`
    4. VSOut struct: `@builtin(position) pos: vec4f`, `@location(0) color: vec3f`
    5. Vertex shader `vs_main(@builtin(vertex_index) vid)`:
       - 6 vertices per segment (2 triangles for thick line quad)
       - segIdx = vid / 6, corner = vid % 6
       - Read smoothed[segIdx] and smoothed[segIdx + 1]
       - Normalize Y using minVal/maxVal
       - Compute X as linear spread across [-1, 1]
       - Compute perpendicular offset for thickness
    6. Fragment shader `fs_main`: return green-ish line color (e.g., vec4f(0.2, 0.9, 0.4, 1.0))
  - **Files**: `gpu-metrics-operator/src/render/line-chart.wgsl`
  - **Done when**: Valid WGSL with vertex + fragment entry points, LineUniforms struct
  - **Verify**: `grep 'fn vs_main' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/line-chart.wgsl && grep 'fn fs_main' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/line-chart.wgsl`
  - **Commit**: `feat(gpu-metrics): implement line chart render shader`
  - _Requirements: AC-5.1 through AC-5.4_
  - _Design: WGSL Contract - line-chart.wgsl_

- [x] 1.11 [P] Implement line chart TypeScript pipeline
  - **Do**:
    1. Create `src/render/line-chart.ts`
    2. Import types from `../types` (ChartContext, Chart, WORKGROUP_SIZE, DEFAULT_EMA_ALPHA, DEFAULT_LINE_THICKNESS)
    3. Import RingBuffer type from `../gpu/ring-buffer`
    4. Import createPingPong, createBuffer from `../gpu/buffers`
    5. Import WGSL shader strings: aggregation, smoothing, line-chart
    6. Export `LineChartConfig` interface and `createLineChart(config): Chart` factory
    7. In factory:
       - Create aggregation compute pipeline + bind group (ring @ group 0, AggResult @ group 1)
       - Create smoothing compute pipeline + bind group (ring @ group 0, params+output @ group 1)
       - Create ping-pong buffers (capacity * 4 bytes)
       - Create render pipeline (vertex + fragment from line-chart.wgsl)
       - Create render bind group (smoothed read buffer @ 0, uniforms @ 1)
       - Create uniform buffer for LineUniforms (16 bytes)
       - Create AggResult buffer (16 bytes, STORAGE)
       - Create SmoothParams buffer (16 bytes, UNIFORM)
    8. `frame(encoder)`:
       - Return false if count < 2
       - Dispatch aggregation compute: ceil(count / 64) workgroups
       - Write SmoothParams uniform (alpha, count)
       - Dispatch smoothing compute: 1 workgroup
       - Write LineUniforms (pointCount, thickness, minVal=0, maxVal=1 for POC)
       - Begin render pass with canvas texture, clear color dark
       - Set pipeline, bind groups, draw(6 * (count - 1))
       - End render pass
       - pingPong.swap()
       - Return true
    9. `markDirty()`: set internal dirty flag
    10. `destroy()`: destroy all GPU buffers
  - **Files**: `gpu-metrics-operator/src/render/line-chart.ts`
  - **Done when**: Exports `createLineChart` that returns Chart interface with frame/markDirty/destroy
  - **Verify**: `grep 'export.*function createLineChart' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/line-chart.ts && grep 'frame.*encoder.*GPUCommandEncoder' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/line-chart.ts`
  - **Commit**: `feat(gpu-metrics): implement line chart pipeline with compute + render`
  - _Requirements: US-4, US-5, AC-4.1 through AC-4.5, AC-5.1 through AC-5.5_
  - _Design: Component 5 (Line Chart)_

- [x] 1.12 [P] [VERIFY] Group 2 quality checkpoint: typecheck
  - **Do**: Run typecheck to verify line chart code compiles with Group 1 types
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit`
  - **Done when**: Zero type errors
  - **Commit**: `chore(gpu-metrics): pass group 2 quality checkpoint` (only if fixes needed)

---

### Group 3: Heatmap [P]

**Files owned** (3): `gpu-metrics-operator/src/compute/heatmap-bin.wgsl`, `gpu-metrics-operator/src/render/heatmap.ts`, `gpu-metrics-operator/src/render/heatmap.wgsl`

- [x] 1.13 [P] Implement heatmap binning compute shader
  - **Do**:
    1. Create `src/compute/heatmap-bin.wgsl`
    2. Declare RingMeta struct and ring buffer bindings at group(0)
    3. Implement ringIndex() helper
    4. Declare HeatmapParams at group(1) binding(0): `{gridSize: u32, _pad1-3: u32}`
    5. Declare bins at group(1) binding(1): `var<storage, read_write> bins: array<atomic<u32>>`
    6. Entry point `clear` @workgroup_size(64): atomicStore(&bins[gid.x], 0u) for gid.x < gridSize*gridSize
    7. Entry point `bin` @workgroup_size(64):
       - Early return if gid.x >= ringMeta.count
       - Read (x, y) pair from ring: idx = ringIndex(gid.x), x = ringData[idx], y = ringData[idx+1]
       - Compute cellX = min(u32(x * gridSize), gridSize-1)
       - Compute cellY = min(u32(y * gridSize), gridSize-1)
       - atomicAdd(&bins[cellY * gridSize + cellX], 1u)
  - **Files**: `gpu-metrics-operator/src/compute/heatmap-bin.wgsl`
  - **Done when**: Two entry points (clear, bin) with atomic operations
  - **Verify**: `grep 'fn clear' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/heatmap-bin.wgsl && grep 'fn bin' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/heatmap-bin.wgsl && grep 'atomicAdd' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/heatmap-bin.wgsl`
  - **Commit**: `feat(gpu-metrics): implement heatmap binning compute shader`
  - _Requirements: AC-6.1_
  - _Design: WGSL Contract - heatmap-bin.wgsl_

- [x] 1.14 [P] Implement heatmap render shader
  - **Do**:
    1. Create `src/render/heatmap.wgsl`
    2. Declare `HeatmapUniforms` at group(0) binding(1): `{gridSize: u32, maxCount: u32, _pad1: u32, _pad2: u32}`
    3. Declare bins at group(0) binding(0): `var<storage, read> bins: array<u32>`
    4. VSOut: `@builtin(position) pos`, `@location(0) uv: vec2f`
    5. Vertex shader `vs_main(@builtin(vertex_index) vid)`:
       - Full-screen quad: 6 vertices mapping to 2 triangles
       - positions (-1,-1), (1,-1), (-1,1), (-1,1), (1,-1), (1,1)
       - UVs (0,0) to (1,1)
    6. Fragment shader `fs_main`:
       - Compute cell from UV: cellX/Y = min(u32(uv * gridSize), gridSize-1)
       - Read count = bins[cellY * gridSize + cellX]
       - Normalize: t = f32(count) / f32(max(maxCount, 1))
       - Color ramp: blue(low) -> yellow(mid) -> red(high) using smoothstep
  - **Files**: `gpu-metrics-operator/src/render/heatmap.wgsl`
  - **Done when**: Full-screen quad vertex shader + color-ramp fragment shader
  - **Verify**: `grep 'fn vs_main' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/heatmap.wgsl && grep 'fn fs_main' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/heatmap.wgsl && grep 'smoothstep' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/heatmap.wgsl`
  - **Commit**: `feat(gpu-metrics): implement heatmap render shader with color ramp`
  - _Requirements: AC-6.2, AC-6.3, AC-6.4_
  - _Design: WGSL Contract - heatmap.wgsl_

- [x] 1.15 [P] Implement heatmap TypeScript pipeline
  - **Do**:
    1. Create `src/render/heatmap.ts`
    2. Import types: ChartContext, Chart, WORKGROUP_SIZE, DEFAULT_HEATMAP_GRID_SIZE from ../types
    3. Import RingBuffer from ../gpu/ring-buffer, createBuffer from ../gpu/buffers
    4. Import WGSL: heatmap-bin, heatmap render
    5. Export `HeatmapConfig` interface and `createHeatmap(config): Chart` factory
    6. In factory:
       - Create bin buffer: gridSize * gridSize * 4 bytes, usage STORAGE
       - Create HeatmapParams uniform (16 bytes)
       - Create 2 compute pipelines from same WGSL module: clear (entry: "clear"), bin (entry: "bin")
       - Create compute bind groups: ring @ group 0, params+bins @ group 1
       - Create render pipeline from heatmap.wgsl
       - Create HeatmapUniforms buffer (16 bytes)
       - Create render bind group: bins @ 0, uniforms @ 1
    7. `frame(encoder)`:
       - Return false if count < 1
       - Write HeatmapParams (gridSize)
       - Dispatch clear: ceil(gridSize*gridSize / 64)
       - Dispatch bin: ceil(count / 64)
       - Write HeatmapUniforms (gridSize, maxCount heuristic)
       - Begin render pass, draw(6), end
       - Return true
    8. `markDirty()` + `destroy()`
  - **Files**: `gpu-metrics-operator/src/render/heatmap.ts`
  - **Done when**: Exports createHeatmap returning Chart interface
  - **Verify**: `grep 'export.*function createHeatmap' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/heatmap.ts && grep 'frame.*encoder.*GPUCommandEncoder' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/heatmap.ts`
  - **Commit**: `feat(gpu-metrics): implement heatmap pipeline with clear + bin + render`
  - _Requirements: US-6, AC-6.1 through AC-6.5_
  - _Design: Component 6 (Heatmap)_

- [x] 1.16 [P] [VERIFY] Group 3 quality checkpoint: typecheck
  - **Do**: Run typecheck to verify heatmap code compiles with Group 1 types
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit`
  - **Done when**: Zero type errors
  - **Commit**: `chore(gpu-metrics): pass group 3 quality checkpoint` (only if fixes needed)

---

### Group 4: Histogram [P]

**Files owned** (3): `gpu-metrics-operator/src/compute/histogram-bin.wgsl`, `gpu-metrics-operator/src/render/histogram.ts`, `gpu-metrics-operator/src/render/histogram.wgsl`

- [x] 1.17 [P] Implement histogram binning compute shader
  - **Do**:
    1. Create `src/compute/histogram-bin.wgsl`
    2. Declare RingMeta struct and ring buffer bindings at group(0)
    3. Implement ringIndex() helper
    4. Declare HistParams at group(1) binding(0): `{numBins: u32, _pad1-3: u32}`
    5. Declare bins at group(1) binding(1): `var<storage, read_write> bins: array<atomic<u32>>`
    6. Entry point `clear` @workgroup_size(64): atomicStore(&bins[gid.x], 0u) for gid.x < numBins
    7. Entry point `bin` @workgroup_size(64):
       - Early return if gid.x >= ringMeta.count
       - Read value: idx = ringIndex(gid.x), v = clamp(ringData[idx], 0.0, 1.0)
       - b = min(u32(v * f32(numBins)), numBins - 1u)
       - atomicAdd(&bins[b], 1u)
  - **Files**: `gpu-metrics-operator/src/compute/histogram-bin.wgsl`
  - **Done when**: Two entry points (clear, bin) with atomic bin counting
  - **Verify**: `grep 'fn clear' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/histogram-bin.wgsl && grep 'fn bin' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/histogram-bin.wgsl && grep 'atomicAdd' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/compute/histogram-bin.wgsl`
  - **Commit**: `feat(gpu-metrics): implement histogram binning compute shader`
  - _Requirements: AC-7.1, AC-7.2_
  - _Design: WGSL Contract - histogram-bin.wgsl_

- [x] 1.18 [P] Implement histogram render shader
  - **Do**:
    1. Create `src/render/histogram.wgsl`
    2. Declare `HistUniforms` at group(0) binding(1): `{numBins: u32, maxCount: u32, _pad1: u32, _pad2: u32}`
    3. Declare bins at group(0) binding(0): `var<storage, read> bins: array<u32>`
    4. Vertex shader `vs_main(@builtin(vertex_index) vid, @builtin(instance_index) iid)`:
       - 6 vertices per bar (quad), instanced by numBins
       - binWidth = 2.0 / f32(numBins) in NDC
       - height = f32(bins[iid]) / f32(max(maxCount, 1)) * 2.0
       - left = -1.0 + f32(iid) * binWidth, right = left + binWidth * 0.9
       - bottom = -1.0, top = bottom + height
       - Map vid (0-5) to quad corners: BL, BR, TL, TL, BR, TR
    5. Fragment shader `fs_main`: return steel blue vec4f(0.35, 0.65, 0.95, 1.0)
  - **Files**: `gpu-metrics-operator/src/render/histogram.wgsl`
  - **Done when**: Instanced bar vertex shader + fragment shader
  - **Verify**: `grep 'fn vs_main' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/histogram.wgsl && grep 'instance_index' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/histogram.wgsl`
  - **Commit**: `feat(gpu-metrics): implement histogram render shader with instanced bars`
  - _Requirements: AC-7.3, AC-7.4, AC-7.5_
  - _Design: WGSL Contract - histogram.wgsl_

- [x] 1.19 [P] Implement histogram TypeScript pipeline
  - **Do**:
    1. Create `src/render/histogram.ts`
    2. Import types: ChartContext, Chart, WORKGROUP_SIZE, DEFAULT_HISTOGRAM_BINS from ../types
    3. Import RingBuffer from ../gpu/ring-buffer, createBuffer from ../gpu/buffers
    4. Import WGSL: histogram-bin, histogram render
    5. Export `HistogramConfig` interface and `createHistogram(config): Chart` factory
    6. In factory:
       - Create bin buffer: numBins * 4 bytes, usage STORAGE
       - Create HistParams uniform (16 bytes)
       - Create 2 compute pipelines: clear (entry: "clear"), bin (entry: "bin")
       - Create compute bind groups: ring @ group 0, params+bins @ group 1
       - Create render pipeline from histogram.wgsl
       - Create HistUniforms buffer (16 bytes)
       - Create render bind group: bins @ 0, uniforms @ 1
    7. `frame(encoder)`:
       - Return false if count < 1
       - Write HistParams (numBins)
       - Dispatch clear: ceil(numBins / 64)
       - Dispatch bin: ceil(count / 64)
       - Write HistUniforms (numBins, maxCount = max(count / numBins * 3, 1))
       - Begin render pass, draw(6, numBins) (instanced), end
       - Return true
    8. `markDirty()` + `destroy()`
  - **Files**: `gpu-metrics-operator/src/render/histogram.ts`
  - **Done when**: Exports createHistogram returning Chart interface
  - **Verify**: `grep 'export.*function createHistogram' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/histogram.ts && grep 'frame.*encoder.*GPUCommandEncoder' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/render/histogram.ts`
  - **Commit**: `feat(gpu-metrics): implement histogram pipeline with clear + bin + instanced render`
  - _Requirements: US-7, AC-7.1 through AC-7.5_
  - _Design: Component 7 (Histogram)_

- [x] 1.20 [P] [VERIFY] Group 4 quality checkpoint: typecheck
  - **Do**: Run typecheck to verify histogram code compiles with Group 1 types
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit`
  - **Done when**: Zero type errors
  - **Commit**: `chore(gpu-metrics): pass group 4 quality checkpoint` (only if fixes needed)

---

### Phase 1 Boundary: [VERIFY] All Groups Merge

- [x] 1.21 [VERIFY] Phase 1 parallel merge checkpoint: typecheck all groups
  - **Do**:
    1. All 4 groups' files now exist in the same tree
    2. Run full typecheck across all source files
    3. Fix any cross-group type mismatches (e.g., interface drift between group 1 types and group 2-4 consumers)
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit`
  - **Done when**: Zero type errors across all 18 files from groups 1-4
  - **Commit**: `chore(gpu-metrics): resolve cross-group type issues` (only if fixes needed)

---

### Group 5: Orchestration (sequential, after Groups 1-4)

**Files owned** (2): `gpu-metrics-operator/src/data/generator.ts`, `gpu-metrics-operator/src/main.ts`

- [x] 1.22 Implement synthetic data generator
  - **Do**:
    1. Create `src/data/generator.ts`
    2. Import RingBuffer type from ../gpu/ring-buffer
    3. Export `GeneratorConfig` interface: `{interval: number, batchSize: number}`
    4. Export `DataGenerator` interface: `{start(): void, stop(): void}`
    5. Export `createGenerator(config, targets, onData)` factory:
       - targets: `{timeSeries: RingBuffer, scatter2D: RingBuffer, values1D: RingBuffer}`
       - Implement Box-Muller gaussian noise helper
       - Time-series formula: `sin(t * 0.02 * PI) * 0.4 + 0.5 + gaussianNoise(0.05)`, clamp [0,1]
       - Scatter 2D: random walk center, points = center + gaussianNoise(0.15), clamp [0,1]
       - Values 1D: `0.5 + gaussianNoise(0.15)`, clamp [0,1]
    6. `start()`: setInterval at config.interval. Each tick:
       - Generate batchSize Float32Array entries per data type
       - Push to respective ring buffers
       - Call onData()
    7. `stop()`: clearInterval
  - **Files**: `gpu-metrics-operator/src/data/generator.ts`
  - **Done when**: Exports createGenerator that produces 3 data streams
  - **Verify**: `grep 'export.*function createGenerator' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/data/generator.ts && grep 'Box-Muller\|gaussianNoise\|boxMuller' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/data/generator.ts`
  - **Commit**: `feat(gpu-metrics): implement synthetic data generator with 3 data streams`
  - _Requirements: AC-2.1 through AC-2.6, NFR-2_
  - _Design: Component 8 (Synthetic Data Generator)_

- [x] 1.23 Implement main.ts orchestrator and render loop
  - **Do**:
    1. Create `src/main.ts`
    2. Import all modules:
       - initGPU, showFallback from ./gpu/device
       - createRingBuffer from ./gpu/ring-buffer
       - createLineChart from ./render/line-chart
       - createHeatmap from ./render/heatmap
       - createHistogram from ./render/histogram
       - createGenerator from ./data/generator
       - DEFAULT_RING_CAPACITY, DEFAULT_DATA_INTERVAL_MS, DEFAULT_BATCH_SIZE from ./types
       - ChartContext type from ./types
    3. Implement async `main()`:
       - Call initGPU(). If null, call showFallback and return.
       - Get 3 canvas elements by ID: line-canvas, heatmap-canvas, histogram-canvas
       - Configure GPUCanvasContext for each: format = navigator.gpu.getPreferredCanvasFormat(), alphaMode: 'premultiplied'
       - Create 3 ring buffers: timeSeries (ch=1, cap=4096), scatter2D (ch=2, cap=4096), values1D (ch=1, cap=4096)
       - Create 3 charts via factories, passing ring buffers
       - Create dirty flag = false
       - Create render loop function:
         ```
         function renderFrame() {
           if (!dirty) return;
           const encoder = device.createCommandEncoder();
           lineChart.frame(encoder);
           heatmap.frame(encoder);
           histogram.frame(encoder);
           device.queue.submit([encoder.finish()]);
           dirty = false;
         }
         ```
       - Create generator with onData callback: `() => { dirty = true; requestAnimationFrame(renderFrame); }`
       - Call generator.start()
    4. Call `main()` at module scope
  - **Files**: `gpu-metrics-operator/src/main.ts`
  - **Done when**: Entry point wires all components, render loop uses dirty flag + rAF
  - **Verify**: `grep 'createLineChart\|createHeatmap\|createHistogram' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/main.ts && grep 'requestAnimationFrame' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/main.ts && grep 'device.queue.submit' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/main.ts`
  - **Commit**: `feat(gpu-metrics): implement orchestrator with render-on-demand loop`
  - _Requirements: US-8, AC-8.1 through AC-8.5, FR-10_
  - _Design: Component 9 (Orchestrator)_

- [x] 1.24 [VERIFY] Full typecheck + Vite build
  - **Do**:
    1. Run typecheck on complete project
    2. Run Vite build to verify bundling works (WGSL imports resolve, no missing deps)
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit && npx vite build`
  - **Done when**: Both typecheck and build succeed with zero errors
  - **Commit**: `chore(gpu-metrics): pass full typecheck and vite build` (only if fixes needed)

- [x] 1.25 POC Checkpoint: verify dev server serves dashboard
  - **Do**:
    1. Start Vite dev server: `npx vite --port 5173 &`
    2. Use WebFetch or curl to verify index.html is served
    3. Verify the built output contains all expected chunks
    4. Kill dev server
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx vite build && ls dist/index.html && ls dist/assets/*.js`
  - **Done when**: Build produces dist/index.html and JS assets containing all shader + TS code
  - **Commit**: `feat(gpu-metrics): complete POC -- all 20 files, build passes`
  - _Requirements: AC-9.2, AC-9.3_

## Phase 2: Refactoring

- [x] 2.1 Extract shared WGSL ring buffer helpers
  - **Do**:
    1. Review all 4 WGSL compute shaders for duplicated RingMeta struct and ringIndex() function
    2. Since WGSL does not support `#include`, duplication is acceptable. Instead, ensure exact consistency:
       - Same RingMeta struct definition across all 4 shaders
       - Same ringIndex() implementation across all 4 shaders
    3. Add comments in each shader referencing the canonical definition in design.md
    4. Optionally: create a TypeScript string constant in types.ts with the WGSL snippet, and prepend at pipeline creation time (alternative to file-level duplication)
  - **Files**: `gpu-metrics-operator/src/compute/aggregation.wgsl`, `gpu-metrics-operator/src/compute/smoothing.wgsl`, `gpu-metrics-operator/src/compute/heatmap-bin.wgsl`, `gpu-metrics-operator/src/compute/histogram-bin.wgsl`
  - **Done when**: All 4 shaders have identical RingMeta + ringIndex code, or shared via TS string concatenation
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && grep -c 'RingMeta' src/compute/*.wgsl | sort`
  - **Commit**: `refactor(gpu-metrics): standardize WGSL ring buffer helpers across shaders`
  - _Design: WGSL Shader Contracts - Shared Ring Buffer Bind Group_

- [x] 2.2 Add error handling to GPU initialization and pipeline creation
  - **Do**:
    1. In `device.ts`: add try/catch around requestAdapter/requestDevice, log specific failure reasons
    2. In `main.ts`: handle device.lost promise -- overlay error message on dashboard
    3. In each chart TS file: wrap createComputePipeline/createRenderPipeline in try/catch, log compilationInfo on failure
    4. In ring-buffer.ts: validate capacity is power-of-2, throw clear error
    5. In main.ts: handle individual canvas context configuration failure (skip that chart, render others)
  - **Files**: `gpu-metrics-operator/src/gpu/device.ts`, `gpu-metrics-operator/src/main.ts`, `gpu-metrics-operator/src/render/line-chart.ts`, `gpu-metrics-operator/src/render/heatmap.ts`, `gpu-metrics-operator/src/render/histogram.ts`, `gpu-metrics-operator/src/gpu/ring-buffer.ts`
  - **Done when**: All error scenarios from design's Error Handling table are covered
  - **Verify**: `grep -c 'catch\|try' /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/gpu/device.ts /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator/src/main.ts`
  - **Commit**: `refactor(gpu-metrics): add comprehensive error handling`
  - _Design: Error Handling table_

- [x] 2.3 [VERIFY] Quality checkpoint: typecheck + build after refactoring
  - **Do**: Verify no regressions from refactoring
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit && npx vite build`
  - **Done when**: Both pass with zero errors
  - **Commit**: `chore(gpu-metrics): pass post-refactoring quality checkpoint` (only if fixes needed)

## Phase 3: Testing

Note: WebGPU requires a real browser. jsdom has no WebGPU API. Testing focuses on:
1. Build verification (Vite build succeeds)
2. TypeScript strict mode compliance
3. Static WGSL validation via Vite's WGSL plugin
4. Structural verification (all exports exist, correct signatures)

- [x] 3.1 Add build + typecheck scripts and verify all pass
  - **Do**:
    1. Ensure package.json has scripts: `"typecheck": "tsc --noEmit"`, `"build": "vite build"`, `"dev": "vite"`
    2. Run full local CI: typecheck + build
    3. Verify dist/ output contains index.html and JS bundles
    4. Verify WGSL files are inlined in the JS bundles (grep for shader strings)
  - **Files**: `gpu-metrics-operator/package.json`
  - **Done when**: `npm run typecheck && npm run build` passes
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npm run typecheck && npm run build && ls dist/index.html && grep -l 'workgroup_size' dist/assets/*.js`
  - **Commit**: `test(gpu-metrics): verify build pipeline and WGSL bundling`
  - _Requirements: AC-9.1 through AC-9.5_

- [x] 3.2 Verify file structure matches design spec
  - **Do**:
    1. Check all 20 files exist at correct paths
    2. Verify each file exports the expected functions/interfaces
    3. Cross-reference with design.md File Structure table
  - **Files**: None (verification only)
  - **Done when**: All 20 files present and exporting correct symbols
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && ls src/types.ts src/gpu/device.ts src/gpu/ring-buffer.ts src/gpu/buffers.ts src/compute/aggregation.wgsl src/compute/smoothing.wgsl src/compute/heatmap-bin.wgsl src/compute/histogram-bin.wgsl src/render/line-chart.ts src/render/line-chart.wgsl src/render/heatmap.ts src/render/heatmap.wgsl src/render/histogram.ts src/render/histogram.wgsl src/main.ts src/data/generator.ts index.html package.json tsconfig.json vite.config.ts`
  - **Commit**: None (verification only)
  - _Design: File Structure table_

- [x] 3.3 [VERIFY] Quality checkpoint: full typecheck + build + structure
  - **Do**: Combined verification of all testing tasks
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit && npx vite build && echo "All 20 files verified"`
  - **Done when**: Typecheck passes, build succeeds
  - **Commit**: `chore(gpu-metrics): pass testing phase quality checkpoint` (only if fixes needed)

## Phase 4: Quality Gates

- [x] 4.1 [VERIFY] Full local CI: typecheck + build
  - **Do**: Run complete local CI suite
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit && npx vite build`
  - **Done when**: Build succeeds, typecheck passes, dist/ generated
  - **Commit**: `fix(gpu-metrics): address final quality issues` (only if fixes needed)

- [ ] 4.2 Create PR and verify CI
  - **Do**:
    1. Verify current branch is a feature branch: `git branch --show-current`
    2. If on default branch, STOP and alert user
    3. Push branch: `git push -u origin <branch-name>`
    4. Create PR: `gh pr create --title "feat: GPU metrics operator -- WebGPU dashboard with 3 chart types" --body "<summary>"`
    5. PR body should reference: US-1 through US-9, 20 files, 5 parallel dispatch groups, zero CPU readback
  - **Verify**: `gh pr checks --watch` -- all checks must show passing
  - **Done when**: All CI checks green, PR ready for review
  - **If CI fails**: Read failures via `gh pr checks`, fix locally, push, re-verify

## Phase 5: PR Lifecycle

- [ ] 5.1 Monitor CI and fix failures
  - **Do**:
    1. Check CI status: `gh pr checks`
    2. If any check fails, read logs and fix
    3. Push fixes and re-check
  - **Verify**: `gh pr checks` shows all passing
  - **Done when**: All CI checks green
  - **Commit**: `fix(gpu-metrics): resolve CI failures` (if needed)

- [ ] 5.2 Address code review comments
  - **Do**:
    1. Check for review comments: `gh api repos/{owner}/{repo}/pulls/{pr}/comments`
    2. Address each comment with code changes
    3. Push fixes
  - **Verify**: `gh pr checks` still passing after fixes
  - **Done when**: All review comments resolved
  - **Commit**: `fix(gpu-metrics): address review feedback`

- [ ] 5.3 [VERIFY] Final validation: typecheck + build + AC checklist
  - **Do**:
    1. Run full local CI: typecheck + build
    2. Verify all acceptance criteria programmatically:
       - AC-1.1-1.4: grep for initGPU, requestAdapter, requestDevice, showFallback in device.ts
       - AC-2.1-2.6: grep for Float32Array, writeBuffer, setInterval in generator.ts
       - AC-3.1-3.5: grep for ringData, ringMeta, head, capacity, push in ring-buffer.ts
       - AC-4.1-4.5: grep for AggResult, EMA/smoothing, WORKGROUP_SIZE(64), STORAGE|VERTEX
       - AC-5.1-5.5: grep for smoothed array read, triangle, thickness, createPingPong in line-chart.ts
       - AC-6.1-6.5: grep for atomicAdd, smoothstep, gridSize in heatmap files
       - AC-7.1-7.5: grep for atomicAdd, instance_index, numBins in histogram files
       - AC-8.1-8.5: grep for canvas, CSS grid, overlay, requestAnimationFrame, dirty in index.html + main.ts
       - AC-9.1-9.5: verify wgsl imports, vite dev/build, tsc strict, @webgpu/types
  - **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-metrics-operator && npx tsc --noEmit && npx vite build && grep -l 'requestAdapter' src/gpu/device.ts && grep -l 'Float32Array' src/data/generator.ts && grep -l 'atomicAdd' src/compute/heatmap-bin.wgsl src/compute/histogram-bin.wgsl && grep -l 'createPingPong' src/render/line-chart.ts && grep -l 'instance_index' src/render/histogram.wgsl`
  - **Done when**: All AC verified via grep, build succeeds
  - **Commit**: None (verification only)

- [ ] 5.4 [VERIFY] CI pipeline passes
  - **Do**: Final CI check after all fixes
  - **Verify**: `gh pr checks` shows all green
  - **Done when**: CI pipeline fully passes
  - **Commit**: None

## Parallel Dispatch Map

```
Phase 1 (Parallel):
  Group 1 (Infra):      1.1 -> 1.2 -> 1.3 -> 1.4 -> 1.5 -> 1.6 -> 1.7
  Group 2 (Line Chart):  1.8 -> 1.9 -> 1.10 -> 1.11 -> 1.12
  Group 3 (Heatmap):     1.13 -> 1.14 -> 1.15 -> 1.16
  Group 4 (Histogram):   1.17 -> 1.18 -> 1.19 -> 1.20

Phase 1 Merge:           1.21 (depends on 1.7, 1.12, 1.16, 1.20)

Phase 1 (Sequential):
  Group 5 (Orchestration): 1.22 -> 1.23 -> 1.24 -> 1.25

Phase 2-5: Sequential
```

## File Ownership Map

| Group | Agent | Files (all under gpu-metrics-operator/) |
|-------|-------|-------|
| 1-Infra | Agent A | package.json, tsconfig.json, vite.config.ts, index.html, src/types.ts, src/gpu/device.ts, src/gpu/ring-buffer.ts, src/gpu/buffers.ts |
| 2-Line | Agent B | src/compute/aggregation.wgsl, src/compute/smoothing.wgsl, src/render/line-chart.ts, src/render/line-chart.wgsl |
| 3-Heatmap | Agent C | src/compute/heatmap-bin.wgsl, src/render/heatmap.ts, src/render/heatmap.wgsl |
| 4-Histogram | Agent D | src/compute/histogram-bin.wgsl, src/render/histogram.ts, src/render/histogram.wgsl |
| 5-Orchestration | Any (after merge) | src/main.ts, src/data/generator.ts |

## Notes

- **POC shortcuts taken**:
  - Line chart uses hardcoded minVal=0, maxVal=1 for Y normalization instead of reading aggregation result back. Aggregation shader runs but result not piped to render uniforms in POC.
  - maxCount for heatmap/histogram uses CPU heuristic (count/bins * N) instead of GPU reduction
  - No error recovery (e.g., buffer OOM retry with halved capacity)
  - No device.lost handling
  - Generator does not track random walk state across stop/start cycles
- **Production TODOs** (addressed in Phase 2):
  - Pipe aggregation result to line chart render uniforms for proper Y normalization
  - Add device.lost handler
  - Add try/catch around pipeline creation with compilationInfo logging
  - Add buffer OOM retry logic
  - Consider shared WGSL snippets via TS string concatenation for DRY
- **WebGPU testing limitation**: Cannot run E2E browser tests in this CI environment (no GPU). Verification relies on typecheck + Vite build. Visual confirmation requires manual browser load.
- **Parallel safety**: Groups 1-4 have ZERO file overlap. Group 5 depends on all groups and runs after merge. This is validated by the File Ownership Map above.
