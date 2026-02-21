# Tasks: gpu-graphics-demo

## Phase 1: Setup

- [ ] 1.1 Create project skeleton with Cargo.toml and compilable stubs
  - **Files**: `gpu-graphics-demo/Cargo.toml`, `gpu-graphics-demo/src/main.rs`, `gpu-graphics-demo/src/vertex.rs`, `gpu-graphics-demo/src/uniforms.rs`, `gpu-graphics-demo/src/texture.rs`, `gpu-graphics-demo/src/renderer.rs`, `gpu-graphics-demo/src/terrain.rs`, `gpu-graphics-demo/src/camera.rs`, `gpu-graphics-demo/src/app.rs`, `gpu-graphics-demo/shaders/terrain.wgsl`
  - **Do**:
    1. Create directories: `gpu-graphics-demo/src/` and `gpu-graphics-demo/shaders/`
    2. Create `Cargo.toml` with dependencies: wgpu 28.0, winit 0.30, pollster 0.3, glam 0.32 (features=["bytemuck"]), bytemuck 1.9 (features=["derive"]), noise 0.9, env_logger 0.10, log 0.4, anyhow 1.0
    3. Create `src/main.rs` with all mod declarations and stub main: `mod vertex; mod uniforms; mod texture; mod renderer; mod terrain; mod camera; mod app; fn main() { println!("gpu-graphics-demo stub"); }`
    4. Create stub `src/vertex.rs`: Vertex struct with position/normal/color [f32;3] fields, #[repr(C)] + Pod + Zeroable derives, buffer_layout() returning todo!()
    5. Create stub `src/uniforms.rs`: CameraUniform {view_proj: [[f32;4];4]} and LightUniform {direction: [f32;4], color: [f32;4]}, both with Pod+Zeroable, new() -> todo!(), update_view_proj() -> todo!()
    6. Create stub `src/texture.rs`: pub const DEPTH_FORMAT + create_depth_texture() -> todo!()
    7. Create stub `src/renderer.rs`: Renderer struct with PhantomData, async new() -> todo!(), resize/update_camera/render/size -> todo!()
    8. Create stub `src/terrain.rs`: TerrainMesh {vertices, indices}, TerrainConfig with Default impl, generate_terrain() -> todo!()
    9. Create stub `src/camera.rs`: Camera {position, yaw, pitch}, Projection {aspect, fovy, znear, zfar}, CameraController, all methods -> todo!()
    10. Create stub `src/app.rs`: App struct, impl ApplicationHandler with resumed/window_event stubs
    11. Create empty `shaders/terrain.wgsl` with a comment placeholder
    12. Run `cargo check` to verify stubs compile
  - **Verify**: `cd gpu-graphics-demo && cargo check`
  - **Done when**: All stubs compile and cargo check passes

- [ ] 1.2 [VERIFY] Phase 1 checkpoint
  - **Verify**: `cd gpu-graphics-demo && cargo check`
  - **Done when**: Project skeleton compiles with all dependencies resolved

## Phase 2: Implementation

### Group 1: gpu-core [P]
**Files owned** (4): `gpu-graphics-demo/src/vertex.rs`, `gpu-graphics-demo/src/uniforms.rs`, `gpu-graphics-demo/src/texture.rs`, `gpu-graphics-demo/src/renderer.rs`

- [ ] 2.1 Implement vertex.rs — shared Vertex struct and buffer layout
  - **Files**: `gpu-graphics-demo/src/vertex.rs`
  - **Do**:
    1. Replace stub with full implementation of Vertex struct: `#[repr(C)] #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)] pub struct Vertex { pub position: [f32; 3], pub normal: [f32; 3], pub color: [f32; 3] }`
    2. Implement `Vertex::buffer_layout() -> wgpu::VertexBufferLayout<'static>` — stride 36 bytes, attributes at locations 0 (Float32x3, offset 0), 1 (Float32x3, offset 12), 2 (Float32x3, offset 24). Use `wgpu::vertex_attr_array!` macro. Store attributes in a `const` or `static` for `'static` lifetime.
    3. Add unit test `test_vertex_size`: assert `std::mem::size_of::<Vertex>() == 36`
  - **Verify**: `cd gpu-graphics-demo && cargo test vertex`
  - **Done when**: Vertex struct is 36 bytes, buffer_layout returns correct descriptor, test passes

- [ ] 2.2 Implement uniforms.rs — CameraUniform and LightUniform
  - **Files**: `gpu-graphics-demo/src/uniforms.rs`
  - **Do**:
    1. Replace stub with CameraUniform: `#[repr(C)] #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)] pub struct CameraUniform { pub view_proj: [[f32; 4]; 4] }`
    2. Implement `CameraUniform::new()` — returns identity matrix via `glam::Mat4::IDENTITY.to_cols_array_2d()`
    3. Implement `CameraUniform::update_view_proj(&mut self, view: &glam::Mat4, proj: &glam::Mat4)` — computes `(*proj * *view).to_cols_array_2d()`. NOTE: takes raw Mat4 refs, not Camera/Projection types, to avoid cross-group dependency.
    4. Create LightUniform: `#[repr(C)] #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)] pub struct LightUniform { pub direction: [f32; 4], pub color: [f32; 4] }`
    5. Implement `LightUniform::new()` — direction (-0.5, -1.0, -0.3) normalized then padded to [x,y,z,0.0], color [1.0, 1.0, 1.0, 0.0]
    6. Add tests: `test_camera_uniform_size` (64 bytes), `test_light_uniform_size` (32 bytes)
  - **Verify**: `cd gpu-graphics-demo && cargo test uniform`
  - **Done when**: CameraUniform is 64 bytes, LightUniform is 32 bytes, tests pass

- [ ] 2.3 Implement texture.rs — depth texture utility
  - **Files**: `gpu-graphics-demo/src/texture.rs`
  - **Do**:
    1. Replace stub with: `pub const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;`
    2. Implement `pub fn create_depth_texture(device: &wgpu::Device, width: u32, height: u32, label: &str) -> (wgpu::Texture, wgpu::TextureView)` — size (width, height, 1), mip_level_count 1, sample_count 1, usage RENDER_ATTACHMENT | TEXTURE_BINDING, format DEPTH_FORMAT, dimension D2. Create view with default descriptor. Return (texture, view).
  - **Verify**: `cd gpu-graphics-demo && cargo check`
  - **Done when**: Function compiles with correct wgpu types

- [ ] 2.4 Implement renderer.rs — GPU device, pipeline, buffers, render loop
  - **Files**: `gpu-graphics-demo/src/renderer.rs`
  - **Do**:
    1. Replace stub with full Renderer struct: surface, device, queue, config, render_pipeline, vertex_buffer, index_buffer, num_indices, camera_uniform, camera_buffer, light_uniform, light_buffer, uniform_bind_group, depth_texture_view, size
    2. Implement `pub async fn new(window: Arc<Window>, vertices: &[crate::vertex::Vertex], indices: &[u32]) -> Self` — create instance (default backends), surface from Arc window, request adapter (HighPerformance), request device, configure surface (Fifo present mode), load shader via `include_str!("../shaders/terrain.wgsl")`, create bind group layout (binding 0 camera vertex, binding 1 light fragment), create uniform buffers (UNIFORM | COPY_DST), create bind group, create pipeline (TriangleList, Ccw, Back cull, Depth32Float Less), create vertex/index buffers, create depth texture
    3. Implement `pub fn resize(&mut self, new_size: PhysicalSize<u32>)` — guard zero size, update config, reconfigure surface, recreate depth texture
    4. Implement `pub fn update_camera(&mut self, view: &glam::Mat4, proj: &glam::Mat4)` — update camera_uniform, write_buffer
    5. Implement `pub fn render(&mut self) -> Result<(), wgpu::SurfaceError>` — get surface texture, create view, create encoder, begin render pass (clear 0.1/0.2/0.3/1.0, depth 1.0), set pipeline/bind_group/vertex_buffer/index_buffer, draw_indexed, submit, present
    6. Implement `pub fn size(&self) -> PhysicalSize<u32>`
  - **Verify**: `cd gpu-graphics-demo && cargo check`
  - **Done when**: Renderer compiles with all GPU initialization and render logic

### Group 2: terrain [P]
**Files owned** (2): `gpu-graphics-demo/src/terrain.rs`, `gpu-graphics-demo/shaders/terrain.wgsl`

- [ ] 2.5 Implement terrain.rs — FBM noise heightmap and mesh generation
  - **Files**: `gpu-graphics-demo/src/terrain.rs`
  - **Do**:
    1. Replace stub with full implementation. Import `use crate::vertex::Vertex;` and `use noise::{NoiseFn, Fbm, Perlin, MultiFractal};`
    2. TerrainMesh: `pub struct TerrainMesh { pub vertices: Vec<Vertex>, pub indices: Vec<u32> }`
    3. TerrainConfig with fields: grid_size: u32 (128), scale: f32 (100.0), height_scale: f32 (15.0), seed: u32 (42), octaves: usize (6), frequency: f64 (0.02). Implement Default.
    4. Implement `fn height_color(height: f32, height_scale: f32) -> [f32; 3]` — normalize height to [0,1], green below 0.3, brown 0.3-0.7, white above 0.7, lerp at boundaries
    5. Implement `pub fn generate_terrain(config: &TerrainConfig) -> TerrainMesh`:
       - Create `Fbm::<Perlin>::new(config.seed)` with octaves and frequency
       - For each (x,z) in grid_size x grid_size: sample height, compute world pos (centered), assign color
       - Compute per-vertex normals: for each cell compute face normal via cross product, accumulate onto vertices, normalize
       - Build indices: for each cell [i, i+grid_size, i+1, i+1, i+grid_size, i+grid_size+1] where i = z*grid_size+x
    6. Add tests: `test_terrain_mesh_size` (128x128 -> 16384 vertices, 127*127*6=96774 indices), `test_terrain_normals_nonzero` (all normals length > 0.5), `test_height_color_low` (height near 0 -> greenish)
  - **Verify**: `cd gpu-graphics-demo && cargo test terrain`
  - **Done when**: Terrain generates correct mesh dimensions, normals are valid, colors match height

- [ ] 2.6 Create terrain.wgsl — vertex and fragment shader
  - **Files**: `gpu-graphics-demo/shaders/terrain.wgsl`
  - **Do**:
    1. Replace empty placeholder with full WGSL shader
    2. Uniform structs: CameraUniform { view_proj: mat4x4<f32> }, LightUniform { direction: vec4<f32>, color: vec4<f32> }
    3. Bindings: @group(0) @binding(0) camera, @group(0) @binding(1) light
    4. VertexInput: @location(0) position vec3, @location(1) normal vec3, @location(2) color vec3
    5. VertexOutput: @builtin(position) clip_position vec4, @location(0) world_normal vec3, @location(1) color vec3
    6. vs_main: transform position by view_proj, pass normal and color
    7. fs_main: ambient 0.15 + diffuse (dot(normal, -light_dir)) * 0.85, multiply by vertex color and light color
  - **Verify**: `cd gpu-graphics-demo && cargo check`
  - **Done when**: Shader file exists and is referenced by renderer via include_str

### Group 3: camera [P]
**Files owned** (1): `gpu-graphics-demo/src/camera.rs`

- [ ] 2.7 Implement camera.rs — Camera, Projection, CameraController
  - **Files**: `gpu-graphics-demo/src/camera.rs`
  - **Do**:
    1. Replace stub with full implementation using `use glam::{Mat4, Vec3};`
    2. Camera struct: position Vec3, yaw f32, pitch f32. new() -> position (50,30,50), yaw -PI/4, pitch -0.3
    3. Camera::view_matrix() — forward = Vec3::new(yaw.cos()*pitch.cos(), pitch.sin(), yaw.sin()*pitch.cos()).normalize(), return Mat4::look_to_rh(position, forward, Vec3::Y)
    4. Camera::forward() — XZ plane: Vec3::new(yaw.cos(), 0.0, yaw.sin()).normalize()
    5. Camera::right() — Vec3::new(-yaw.sin(), 0.0, yaw.cos()).normalize()
    6. Projection struct: aspect, fovy, znear, zfar. new(w,h) -> fovy PI/4, znear 0.1, zfar 500.0
    7. Projection::resize(w,h) — update aspect. projection_matrix() -> Mat4::perspective_rh(fovy, aspect, znear, zfar)
    8. CameraController: speed, sensitivity, forward/backward/left/right_pressed bools. new(20.0, 0.003)
    9. process_keyboard(KeyCode, ElementState) -> bool — W/S/A/D mapping
    10. process_mouse(&mut Camera, dx, dy) — yaw += dx*sensitivity, pitch -= dy*sensitivity, clamp pitch to [-89deg, 89deg]
    11. update_camera(&Camera, dt) — move along forward/right based on pressed keys, scaled by speed*dt
    12. Tests: test_camera_initial_position (y > 0), test_projection_aspect (800/600 ≈ 1.333), test_pitch_clamp (extreme dy stays in bounds), test_view_matrix_deterministic
  - **Verify**: `cd gpu-graphics-demo && cargo test camera`
  - **Done when**: Camera math is correct, controller handles WASD + mouse, all tests pass

---

- [ ] 2.8 [VERIFY] Phase 2 checkpoint — all modules compile and tests pass
  - **Verify**: `cd gpu-graphics-demo && cargo test && cargo check`
  - **Done when**: All Phase 2 modules compile together, all unit tests pass

## Phase 3: Orchestration

- [ ] 3.1 Implement app.rs and main.rs — wire everything together
  - **Files**: `gpu-graphics-demo/src/app.rs`, `gpu-graphics-demo/src/main.rs`
  - **Do**:
    1. Replace app.rs stub with full App struct: window Option<Arc<Window>>, renderer Option<Renderer<'a>>, camera Camera, projection Projection, camera_controller CameraController, last_frame_time Instant, mouse_captured bool
    2. App::new() — Options as None, Camera::new(), Projection::new(800,600), CameraController::new(20.0, 0.003), Instant::now(), mouse_captured false
    3. Implement ApplicationHandler::resumed() — create window (title "GPU Graphics Demo", 800x600), generate terrain (TerrainConfig::default()), create renderer (pollster::block_on(Renderer::new(window.clone(), &mesh.vertices, &mesh.indices))), update projection, request redraw
    4. Implement window_event: CloseRequested->exit, Escape->release mouse, KeyboardInput->controller, Resized->resize, MouseInput Left->capture cursor, RedrawRequested->compute dt (clamp 0.1), update camera, update_camera(view_matrix, projection_matrix), render, request_redraw
    5. Implement device_event: MouseMotion when captured -> process_mouse
    6. Replace main.rs with: env_logger::init(), EventLoop::new(), set ControlFlow::Poll, create App, run_app
    7. Ensure all mod declarations present in main.rs
  - **Verify**: `cd gpu-graphics-demo && cargo build`
  - **Done when**: Full binary builds successfully

- [ ] 3.2 [VERIFY] Final integration — build, lint, test
  - **Verify**: `cd gpu-graphics-demo && cargo fmt --check && cargo clippy -- -D warnings && cargo build && cargo test`
  - **Done when**: All quality commands pass, binary builds, all unit tests pass
