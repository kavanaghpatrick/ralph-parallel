# Requirements: GPU Graphics Demo

## Goal

Native wgpu terrain renderer on macOS Metal -- procedural terrain with FPS camera, directional lighting, and height-based coloring. Serves as a parallel-ralph stress test for complex Rust builds.

## User Stories

### US-1: Window and GPU Initialization
**As a** developer running the demo
**I want to** run `cargo run` and see a window appear with GPU-rendered content
**So that** I can verify the wgpu/Metal pipeline works end-to-end

**Acceptance Criteria:**
- [ ] AC-1.1: `cargo build` completes with zero errors
- [ ] AC-1.2: `cargo clippy -- -D warnings` passes with zero warnings
- [ ] AC-1.3: Running the binary opens a native macOS window (default ~800x600)
- [ ] AC-1.4: Window title identifies the demo (e.g. "GPU Graphics Demo")
- [ ] AC-1.5: GPU renders frames continuously (not a static image)
- [ ] AC-1.6: Window close (Cmd+Q or X button) exits cleanly without panic

### US-2: Procedural Terrain Rendering
**As a** viewer of the demo
**I want to** see a 3D terrain landscape rendered in the window
**So that** the GPU is doing meaningful geometric work

**Acceptance Criteria:**
- [ ] AC-2.1: Terrain is a 128x128 vertex grid (16,384 vertices, ~32K triangles)
- [ ] AC-2.2: Heights generated via FBM noise (Perlin base) -- terrain looks natural, not flat
- [ ] AC-2.3: Vertices colored by height: green (low), brown (mid), white (peaks)
- [ ] AC-2.4: Terrain renders with indexed triangles (index buffer, not individual triangles)
- [ ] AC-2.5: Depth buffer enabled -- no z-fighting or rendering artifacts from overlapping geometry

### US-3: Directional Lighting
**As a** viewer of the demo
**I want to** see the terrain with light and shadow variation
**So that** the 3D geometry reads as a surface, not a flat blob

**Acceptance Criteria:**
- [ ] AC-3.1: Single directional light applied in fragment shader
- [ ] AC-3.2: Ambient term prevents fully-black shadows (ambient >= 0.1)
- [ ] AC-3.3: Diffuse lighting computed from vertex normals and light direction
- [ ] AC-3.4: Terrain faces oriented away from light are visibly darker than faces toward it

### US-4: FPS Camera Controls
**As a** user exploring the terrain
**I want to** move through the scene with WASD keys and mouse look
**So that** I can view the terrain from different angles

**Acceptance Criteria:**
- [ ] AC-4.1: W/S move camera forward/backward relative to look direction
- [ ] AC-4.2: A/D strafe camera left/right relative to look direction
- [ ] AC-4.3: Mouse movement rotates camera yaw (horizontal) and pitch (vertical)
- [ ] AC-4.4: Camera starts at a position where terrain is visible (not inside or below terrain)
- [ ] AC-4.5: Perspective projection with reasonable FOV (~45-60 degrees)

### US-5: Window Resize
**As a** user
**I want to** resize the window and have rendering adapt
**So that** the image doesn't stretch or break

**Acceptance Criteria:**
- [ ] AC-5.1: Resizing window updates the surface/swapchain configuration
- [ ] AC-5.2: Aspect ratio updates so terrain doesn't appear stretched
- [ ] AC-5.3: Depth buffer recreated on resize to match new dimensions

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | wgpu device/surface init on Metal backend | High | Window opens, GPU adapter acquired |
| FR-2 | Render pipeline with vertex + fragment shaders (WGSL) | High | Terrain renders with correct geometry |
| FR-3 | 128x128 terrain mesh from FBM noise | High | AC-2.1 through AC-2.4 |
| FR-4 | Height-based vertex coloring (green/brown/white) | High | AC-2.3 |
| FR-5 | Vertex normals computed per-face or per-vertex | High | Lighting looks correct (AC-3.3) |
| FR-6 | Depth buffer (TextureFormat::Depth32Float) | High | AC-2.5 |
| FR-7 | Camera uniform buffer (view-projection matrix) | High | Scene transforms correctly with camera |
| FR-8 | Light uniform buffer (direction + color) | High | AC-3.1 through AC-3.4 |
| FR-9 | FPS camera controller (WASD + mouse) | High | AC-4.1 through AC-4.3 |
| FR-10 | winit 0.30 ApplicationHandler event loop | High | AC-1.5, AC-1.6 |
| FR-11 | Window resize handling | Medium | AC-5.1 through AC-5.3 |
| FR-12 | Shaders loaded via include_str!() at compile time | Medium | No runtime file I/O for shaders |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | Frame rate | FPS | >= 60 FPS on Apple Silicon (trivial for 32K triangles) |
| NFR-2 | Build time | Seconds | < 120s clean build, < 15s incremental |
| NFR-3 | Platform | macOS Metal | Runs on macOS 13+ with Metal-capable GPU |
| NFR-4 | Rust toolchain | MSRV | 1.87+ (wgpu v28.0 requirement) |
| NFR-5 | Code quality | Linting | `cargo clippy -- -D warnings` passes |
| NFR-6 | Code quality | Formatting | `cargo fmt --check` passes |
| NFR-7 | Startup time | Seconds | Window visible within 3s of `cargo run` |

## Glossary

- **wgpu**: Rust graphics API implementing WebGPU spec; abstracts Metal/Vulkan/DX12
- **Metal**: Apple's native GPU API; wgpu's backend on macOS
- **WGSL**: WebGPU Shading Language; shader language used by wgpu
- **FBM**: Fractal Brownian Motion; layered noise for natural-looking terrain
- **FPS camera**: First-person shooter style; WASD movement + mouse look
- **Depth buffer**: GPU texture storing per-pixel depth; prevents incorrect draw ordering
- **bytemuck**: Rust crate for safe transmutation of types to byte slices (GPU buffer upload)
- **winit**: Cross-platform window creation library for Rust
- **pollster**: Minimal async runtime; bridges winit's sync API with wgpu's async init

## Out of Scope

- Runtime terrain regeneration (different seeds, reloading)
- Camera bounds enforcement (clipping below terrain, max distance)
- Texture mapping or texture loading
- Shadow maps or advanced lighting (point lights, specular)
- Anti-aliasing (MSAA)
- UI overlay or HUD (FPS counter, debug info)
- Cross-platform testing (Windows, Linux, WASM)
- Unit tests (optional but not required for demo)
- Audio
- Save/load camera position

## Dependencies

- Rust toolchain >= 1.87 installed
- macOS with Metal-capable GPU (all Apple Silicon; Intel Macs 2012+)
- Crates: wgpu 28.0, winit 0.30, glam 0.32, noise 0.9, bytemuck 1.9, pollster 0.3, env_logger 0.10, log 0.4, anyhow 1.0

## Success Criteria

- `cargo build` succeeds with zero errors
- `cargo clippy -- -D warnings` passes
- `cargo fmt --check` passes
- Binary launches, opens a window, renders terrain with lighting
- WASD + mouse controls move the camera through the scene
- Window resize works without crash or visual artifacts

## Parallel Dispatch Notes

Project decomposes into 4 execution groups for parallel dispatch:

| Group | Files | Can Parallel With |
|-------|-------|-------------------|
| 0: Setup | `Cargo.toml` | Runs first |
| 1: GPU Core | `renderer.rs`, `vertex.rs`, `uniforms.rs`, `texture.rs` | Groups 2, 3 |
| 2: Terrain | `terrain.rs`, `shaders/terrain.wgsl` | Groups 1, 3 |
| 3: Camera | `camera.rs` | Groups 1, 2 |
| 4: Orchestration | `main.rs`, `app.rs` | Runs last (depends on 1-3) |

Shared interface: `vertex.rs` defines the `Vertex` struct used by both terrain.rs (mesh generation) and renderer.rs (buffer layout). Must be defined first or in parallel with a contract.

## Unresolved Questions

- None. Research phase resolved all open questions (static terrain, no camera bounds, 60fps trivial).

## Next Steps

1. Approve requirements
2. Design phase: define module interfaces, type contracts, and task breakdown
3. Dispatch: parallel implementation of Groups 1-3, then Group 4 integration
