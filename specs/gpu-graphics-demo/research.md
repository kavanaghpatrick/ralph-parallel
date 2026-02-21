---
spec: gpu-graphics-demo
phase: research
created: 2026-02-21
---

# Research: gpu-graphics-demo

## Executive Summary

Building a native wgpu terrain renderer on macOS Metal is well-supported and low-risk. The ecosystem is production-ready: wgpu v28.0 + winit v0.30.12 + noise v0.9 + glam v0.32 form a proven stack. The project decomposes cleanly into 8-10 files with clear ownership boundaries for parallel dispatch.

## External Research

### Best Practices

- **wgpu v28.0** (Dec 2024) is current stable. Metal backend enabled by default on macOS. Production-ready for desktop. MSRV 1.87. ([source](https://github.com/gfx-rs/wgpu/releases))
- **winit v0.30.12** is current stable. Breaking API change from 0.29: now uses `ApplicationHandler` trait instead of closure-based event loop. ([source](https://crates.io/crates/winit))
- **glam v0.32** (Feb 2026) preferred over cgmath -- native bytemuck support via feature flag, simpler API, better wgpu integration. cgmath requires manual conversion for bytemuck. ([source](https://docs.rs/crate/glam/latest))
- **noise v0.9** provides Perlin, OpenSimplex, FBM (Fractal Brownian Motion). Adequate for terrain heightmaps. ([source](https://github.com/Razaekel/noise-rs))
- **pollster v0.3** for `block_on()` -- the recommended way to bridge winit's sync `ApplicationHandler` with wgpu's async init. ([source](https://sotrh.github.io/learn-wgpu/beginner/tutorial1-window/))

### Recommended Cargo.toml Dependencies

```toml
[package]
name = "gpu-graphics-demo"
version = "0.1.0"
edition = "2021"

[dependencies]
wgpu = "28.0"
winit = "0.30"
pollster = "0.3"
glam = { version = "0.32", features = ["bytemuck"] }
bytemuck = { version = "1.9", features = ["derive"] }
noise = "0.9"
env_logger = "0.10"
log = "0.4"
anyhow = "1.0"
```

### Prior Art

- **Learn Wgpu** (sotrh.github.io/learn-wgpu): Canonical tutorial. Uses State struct pattern, bytemuck for vertex data, separate camera module. ([source](https://sotrh.github.io/learn-wgpu/))
- **wgpu_cube** (FrankenApps): Orbit camera with wgpu, minimal resource usage. ([source](https://github.com/FrankenApps/wgpu_cube))
- **wgpu-voxel-engine**: Terrain chunks with wgpu, noise-based generation. ([source](https://github.com/Blatko1/wgpu-voxel-engine))
- **Bevy terrain generation**: Flat mesh displaced by heightmap, indexed triangles. ([source](http://clynamen.github.io/blog/2021/01/04/terrain_generation_bevy/))

### Pitfalls to Avoid

| Pitfall | Mitigation |
|---------|------------|
| winit 0.30 async conflict -- `resumed()` is sync but wgpu init is async | Use `pollster::block_on()` inside `resumed()` |
| cgmath types don't implement bytemuck traits | Use glam instead (native bytemuck support) |
| Metal shader compilation errors ("constant address space") | Fixed in wgpu 27.0.3+; use v28.0 |
| Surface lifetime tied to Window | Use `Arc<Window>` pattern, store both in App struct |
| Vertex alignment issues | Always use `#[repr(C)]` + bytemuck derives on vertex structs |
| Uniform buffer 16-byte alignment | Pad uniforms to 16-byte boundaries (vec4 instead of vec3 in WGSL) |

## Codebase Analysis

### Existing Patterns

This is a greenfield Rust project -- no existing Cargo workspace in the repo. The project will live in a new `gpu-graphics-demo/` directory at repo root.

### Related Specs

| Spec | Relevance | Overlap | mayNeedUpdate |
|------|-----------|---------|---------------|
| gpu-metrics-operator | Medium | Both use GPU rendering (WebGPU vs wgpu-native). Different tech stack (TS vs Rust). | false |
| parallel-qa-overhaul | Medium | QA pipeline improvements apply to this spec's dispatch. Quality commands (cargo build, cargo clippy) relevant. | false |
| parallel-v2 | Low | Parallel dispatch improvements benefit this spec but no direct code overlap. | false |
| api-dashboard | Low | Tangential -- web dashboard vs native GPU app. | false |

### Dependencies

- Rust toolchain (1.87+ for wgpu MSRV)
- macOS with Metal support (all Apple Silicon, Intel Macs with Metal GPU)
- No external C/C++ dependencies -- wgpu handles Metal bindings through objc2-metal

### Constraints

- macOS Metal only (no Vulkan/DX12 needed)
- No WASM target (native-only simplifies architecture)
- Terrain mesh is CPU-generated, uploaded once to GPU (no compute shaders needed for MVP)

## Architecture: Recommended Project Structure

Designed for parallel task execution -- each file has a single owner with minimal cross-file dependencies.

```
gpu-graphics-demo/
  Cargo.toml              # Group 0: Setup
  src/
    main.rs               # Group 4: Orchestration (entry point, event loop)
    app.rs                # Group 4: Orchestration (App struct, ApplicationHandler impl)
    renderer.rs           # Group 1: GPU Core (device, surface, pipeline, render loop)
    vertex.rs             # Group 1: GPU Core (Vertex struct, buffer layouts)
    terrain.rs            # Group 2: Terrain (heightmap generation, mesh construction)
    camera.rs             # Group 3: Camera (Camera struct, Projection, CameraController)
    uniforms.rs           # Group 1: GPU Core (CameraUniform, LightUniform, bind groups)
    texture.rs            # Group 1: GPU Core (depth texture creation) [optional]
  shaders/
    terrain.wgsl          # Group 2: Terrain (vertex + fragment shader)
```

### File Ownership Groups (for parallel dispatch)

| Group | Files | Description | Dependencies |
|-------|-------|-------------|-------------|
| 0: Setup | `Cargo.toml` | Project config, dependencies | None |
| 1: GPU Core | `renderer.rs`, `vertex.rs`, `uniforms.rs`, `texture.rs` | Device init, pipeline, buffers, uniforms | Group 0 |
| 2: Terrain | `terrain.rs`, `shaders/terrain.wgsl` | Heightmap + mesh generation, WGSL shaders | Group 0 (types from vertex.rs at interface level) |
| 3: Camera | `camera.rs` | Camera position, projection, input handling | Group 0 |
| 4: Orchestration | `main.rs`, `app.rs` | Event loop, wiring everything together | Groups 1-3 |

**Key design for parallelism**: Groups 1, 2, 3 can execute in parallel. They share only type interfaces (Vertex struct shape, uniform layouts) defined in their contracts. Group 4 depends on all others and runs last.

### Key Code Patterns

#### Vertex Definition (vertex.rs)

```rust
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Vertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub color: [f32; 3],
}
```

#### Terrain Mesh Generation (terrain.rs)

```rust
pub struct TerrainMesh {
    pub vertices: Vec<Vertex>,
    pub indices: Vec<u32>,
}

pub fn generate_terrain(width: u32, depth: u32, scale: f64) -> TerrainMesh {
    // 1. Generate heightmap using noise::Fbm<noise::Perlin>
    // 2. Create vertex grid: (x, height, z) with computed normals
    // 3. Build index buffer: 2 triangles per grid cell
    //    For each cell (x,z): indices push [i, i+width, i+1, i+1, i+width, i+width+1]
}
```

#### Camera (camera.rs)

```rust
pub struct Camera {
    pub position: glam::Vec3,
    pub yaw: f32,    // radians
    pub pitch: f32,  // radians
}

pub struct Projection {
    pub aspect: f32,
    pub fovy: f32,
    pub znear: f32,
    pub zfar: f32,
}

pub struct CameraController {
    speed: f32,
    sensitivity: f32,
    // WASD + mouse movement
}
```

#### App with winit 0.30 (app.rs)

```rust
pub struct App<'a> {
    window: Option<Arc<Window>>,
    renderer: Option<Renderer<'a>>,
}

impl ApplicationHandler for App<'_> {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        let window = Arc::new(event_loop.create_window(Window::default_attributes()).unwrap());
        self.renderer = Some(pollster::block_on(Renderer::new(window.clone())));
        self.window = Some(window);
    }
    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        // Handle input, resize, render on RedrawRequested
    }
}
```

#### WGSL Shader (terrain.wgsl)

```wgsl
struct CameraUniform {
    view_proj: mat4x4<f32>,
};

struct Light {
    direction: vec3<f32>,
    color: vec3<f32>,
};

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_normal: vec3<f32>,
    @location(1) color: vec3<f32>,
};

@group(0) @binding(0) var<uniform> camera: CameraUniform;
@group(0) @binding(1) var<uniform> light: Light;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = camera.view_proj * vec4<f32>(in.position, 1.0);
    out.world_normal = in.normal;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let ambient = 0.15;
    let diffuse = max(dot(normalize(in.world_normal), normalize(light.direction)), 0.0);
    let brightness = ambient + diffuse * 0.85;
    return vec4<f32>(in.color * brightness * light.color, 1.0);
}
```

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | **High** | All crates are production-ready, Metal is first-class in wgpu |
| Effort Estimate | **M** | ~8-10 files, well-documented patterns exist |
| Risk Level | **Low** | Proven stack, no experimental APIs needed |
| Parallel Suitability | **High** | Clean file boundaries, 3 independent groups + orchestration |

## Quality Commands

| Type | Command | Source |
|------|---------|--------|
| Build | `cargo build` | Cargo standard |
| Check (fast) | `cargo check` | Cargo standard |
| Lint | `cargo clippy -- -D warnings` | Cargo standard |
| Test | `cargo test` | Cargo standard (unit tests if any) |
| Format | `cargo fmt --check` | Cargo standard |
| Run | `cargo run` | Cargo standard |

**Local CI**: `cargo fmt --check && cargo clippy -- -D warnings && cargo build`

Note: No `cargo test` in local CI by default since this is a visual demo. Unit tests for terrain generation and camera math are optional but recommended for parallel verification.

## Recommendations for Requirements

1. **Use glam over cgmath** -- native bytemuck support avoids boilerplate, simpler API for 3D math
2. **FPS-style camera** (WASD + mouse look) is simpler than orbit and more appropriate for terrain exploration
3. **Height-based vertex coloring** (green low, brown mid, white peaks) avoids texture loading complexity while still looking good
4. **Fractal Brownian Motion** (FBM over Perlin) for terrain -- single noise octave looks flat; FBM adds natural detail
5. **Depth buffer required** -- terrain has overlapping geometry from camera perspective; without depth testing, rendering artifacts
6. **Directional light** (sun-like) is simplest lighting model -- single direction vector, no attenuation math
7. **128x128 terrain grid** is a good default -- 16K vertices, 32K triangles. Renders instantly on Metal, visually interesting
8. **Separate `vertex.rs`** for the Vertex struct -- both `terrain.rs` and `renderer.rs` need it; isolating it prevents ownership conflicts in parallel dispatch
9. **Keep shaders in a `shaders/` directory** as `.wgsl` files loaded at compile time via `include_str!()` -- avoids runtime file loading
10. **Group 4 (orchestration) must run after Groups 1-3** -- it wires everything together and is the integration point

## Open Questions

- Should terrain be regenerable at runtime (e.g., different seeds) or static once generated? Recommend static for MVP.
- Target FPS? 60fps is trivial for this mesh size on Metal. No optimization needed.
- Should camera bounds be enforced (prevent flying below terrain)? Recommend no for MVP -- simpler implementation.

## Sources

- [wgpu GitHub releases](https://github.com/gfx-rs/wgpu/releases) -- v28.0 Dec 2024
- [Learn Wgpu tutorial](https://sotrh.github.io/learn-wgpu/) -- canonical patterns
- [winit crates.io](https://crates.io/crates/winit) -- v0.30.12
- [noise-rs GitHub](https://github.com/Razaekel/noise-rs) -- v0.9
- [glam crates.io](https://crates.io/crates/glam) -- v0.32
- [winit 0.30 + wgpu discussion](https://github.com/rust-windowing/winit/discussions/3667) -- ApplicationHandler pattern
- [Learn Wgpu: Buffers and Indices](https://sotrh.github.io/learn-wgpu/beginner/tutorial4-buffer/) -- vertex layout
- [Learn Wgpu: Lighting](https://sotrh.github.io/learn-wgpu/intermediate/tutorial10-lighting/) -- WGSL lighting
- [Learn Wgpu: Camera](https://sotrh.github.io/learn-wgpu/intermediate/tutorial12-camera/) -- FPS camera
- [Procedural Terrain in Rust](https://peerdh.com/blogs/programming-insights/procedural-terrain-generation-in-rust-a-comprehensive-guide) -- mesh generation
- [wgpu cross-platform guide](https://www.blog.brightcoding.dev/2025/09/30/cross-platform-rust-graphics-with-wgpu-one-api-to-rule-vulkan-metal-d3d12-opengl-webgpu/) -- Metal backend
- [Rust GPU programming guide](https://tillcode.com/rust-for-gpu-programming-wgpu-and-rust-gpu/) -- wgpu overview
