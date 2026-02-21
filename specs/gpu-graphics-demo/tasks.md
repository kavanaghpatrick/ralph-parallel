# Tasks: gpu-graphics-demo

## Task 1: Create project skeleton with Cargo.toml
- **Files**: gpu-graphics-demo/Cargo.toml, gpu-graphics-demo/src/main.rs
- **Depends on**: (none)
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo check`

### Steps
1. Create directory structure: `gpu-graphics-demo/src/` and `gpu-graphics-demo/shaders/`
2. Create `Cargo.toml` with exact dependencies from research:
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
3. Create minimal `src/main.rs` stub that compiles:
   ```rust
   fn main() {
       println!("gpu-graphics-demo stub");
   }
   ```
4. Run `cargo check` to verify dependencies resolve

## Task 2: Implement vertex.rs -- shared Vertex struct and buffer layout
- **Files**: gpu-graphics-demo/src/vertex.rs
- **Depends on**: 1
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo test --lib test_vertex`

### Steps
1. Create `src/vertex.rs` with the shared Vertex type contract:
   ```rust
   use bytemuck::{Pod, Zeroable};

   #[repr(C)]
   #[derive(Copy, Clone, Debug, Pod, Zeroable)]
   pub struct Vertex {
       pub position: [f32; 3],
       pub normal: [f32; 3],
       pub color: [f32; 3],
   }
   ```
2. Implement `Vertex::buffer_layout()` returning `wgpu::VertexBufferLayout<'static>`:
   - Stride: 36 bytes (9 x f32)
   - Attributes at locations 0 (position, Float32x3, offset 0), 1 (normal, Float32x3, offset 12), 2 (color, Float32x3, offset 24)
   - Use `wgpu::vertex_attr_array!` macro for attributes
   - Store attributes in a `const` or `static` array so the returned layout has `'static` lifetime
3. Add unit test `test_vertex_size` asserting `std::mem::size_of::<Vertex>() == 36`
4. Add `pub mod vertex;` to main.rs (keep the main fn stub)

## Task 3: Implement uniforms.rs -- CameraUniform and LightUniform
- **Files**: gpu-graphics-demo/src/uniforms.rs
- **Depends on**: 1
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo test --lib test_uniform`

### Steps
1. Create `src/uniforms.rs` with CameraUniform struct:
   ```rust
   #[repr(C)]
   #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
   pub struct CameraUniform {
       pub view_proj: [[f32; 4]; 4],
   }
   ```
2. Implement `CameraUniform::new()` returning identity matrix (glam::Mat4::IDENTITY.to_cols_array_2d())
3. Implement `CameraUniform::update_view_proj(&mut self, view: &glam::Mat4, proj: &glam::Mat4)`:
   - Computes `proj * view` and stores as `view_proj`
   - NOTE: Takes raw matrices (not Camera/Projection types) to avoid cross-group dependency during parallel build. The app.rs integration layer will extract matrices and pass them in.
4. Create LightUniform struct:
   ```rust
   #[repr(C)]
   #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
   pub struct LightUniform {
       pub direction: [f32; 4],  // .xyz = normalized dir, .w = padding
       pub color: [f32; 4],      // .xyz = RGB, .w = padding
   }
   ```
5. Implement `LightUniform::new()` with default sun direction (-0.5, -1.0, -0.3) normalized, padded to vec4, and white light (1.0, 1.0, 1.0, 0.0)
6. Add unit tests:
   - `test_camera_uniform_size`: assert `size_of::<CameraUniform>() == 64`
   - `test_light_uniform_size`: assert `size_of::<LightUniform>() == 32`
7. Add `pub mod uniforms;` to main.rs

## Task 4: Implement texture.rs -- depth texture utility
- **Files**: gpu-graphics-demo/src/texture.rs
- **Depends on**: 1
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo check`

### Steps
1. Create `src/texture.rs` with:
   ```rust
   pub const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;
   ```
2. Implement `create_depth_texture(device: &wgpu::Device, width: u32, height: u32, label: &str) -> (wgpu::Texture, wgpu::TextureView)`:
   - Create texture with size (width, height, 1), mip_level_count 1, sample_count 1
   - Usage: `TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING`
   - Format: `DEPTH_FORMAT`
   - Dimension: D2
   - Create view with `texture.create_view(&wgpu::TextureViewDescriptor::default())`
   - Return (texture, view)
3. Add `pub mod texture;` to main.rs

## Task 5: Implement renderer.rs -- GPU device, pipeline, buffers, render
- **Files**: gpu-graphics-demo/src/renderer.rs
- **Depends on**: 1, 2, 3, 4
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo check`

### Steps
1. Create `src/renderer.rs` with Renderer struct containing:
   - `surface: wgpu::Surface<'a>`, `device: wgpu::Device`, `queue: wgpu::Queue`
   - `config: wgpu::SurfaceConfiguration`, `render_pipeline: wgpu::RenderPipeline`
   - `vertex_buffer: wgpu::Buffer`, `index_buffer: wgpu::Buffer`, `num_indices: u32`
   - `camera_uniform: CameraUniform`, `camera_buffer: wgpu::Buffer`
   - `light_uniform: LightUniform`, `light_buffer: wgpu::Buffer`
   - `uniform_bind_group: wgpu::BindGroup`, `depth_texture_view: wgpu::TextureView`
   - `size: winit::dpi::PhysicalSize<u32>`
2. Implement `async fn new(window: Arc<Window>, vertices: &[Vertex], indices: &[u32]) -> Self`:
   - Create wgpu instance (default backends)
   - Create surface from window (Arc)
   - Request adapter (power_preference: HighPerformance, compatible_surface)
   - Request device (default limits + features)
   - Configure surface (first compatible format, PresentMode::Fifo, width/height from window)
   - Load shader: `device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("Terrain Shader"), source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/terrain.wgsl").into()) })`
   - Create bind group layout: binding 0 = CameraUniform (vertex visibility), binding 1 = LightUniform (fragment visibility)
   - Create camera buffer + light buffer as uniform buffers with COPY_DST usage
   - Create bind group with both buffers
   - Create pipeline layout from bind group layout
   - Create render pipeline:
     - Vertex: vs_main entry, Vertex::buffer_layout()
     - Fragment: fs_main entry, surface format
     - Primitive: TriangleList, Ccw front face, Back cull
     - Depth stencil: Depth32Float, Less compare, write enabled
   - Create vertex buffer (VERTEX usage, init with bytemuck::cast_slice(vertices))
   - Create index buffer (INDEX usage, init with bytemuck::cast_slice(indices))
   - Create depth texture via texture::create_depth_texture()
3. Implement `resize(&mut self, new_size: PhysicalSize<u32>)`:
   - Guard: return if width or height is 0
   - Update self.size, self.config.width/height
   - Reconfigure surface
   - Recreate depth texture
4. Implement `update_camera(&mut self, view_matrix: &glam::Mat4, proj_matrix: &glam::Mat4)`:
   - Call camera_uniform.update_view_proj(view, proj)
   - queue.write_buffer(&camera_buffer, 0, bytemuck::cast_slice(&[camera_uniform]))
5. Implement `render(&mut self) -> Result<(), wgpu::SurfaceError>`:
   - Get current surface texture
   - Create texture view
   - Create command encoder
   - Begin render pass: clear color (0.1, 0.2, 0.3, 1.0), depth clear 1.0, load Op::Clear, store Op::Store
   - Set pipeline, set bind group 0, set vertex buffer slot 0, set index buffer (Uint32)
   - draw_indexed(0..num_indices, 0, 0..1)
   - Drop render pass, submit encoder
   - Present surface texture
6. Implement `pub fn size(&self) -> PhysicalSize<u32>`
7. Add `pub mod renderer;` to main.rs

## Task 6: Implement terrain.rs -- FBM noise heightmap and mesh generation
- **Files**: gpu-graphics-demo/src/terrain.rs
- **Depends on**: 1, 2
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo test --lib test_terrain`

### Steps
1. Create `src/terrain.rs` importing `crate::vertex::Vertex`
2. Define `TerrainMesh` struct:
   ```rust
   pub struct TerrainMesh {
       pub vertices: Vec<Vertex>,
       pub indices: Vec<u32>,
   }
   ```
3. Define `TerrainConfig` struct with defaults:
   - grid_size: 128, scale: 100.0, height_scale: 15.0, seed: 42, octaves: 6, frequency: 0.02
   - Implement `Default` trait
4. Implement `height_color(height: f32, height_scale: f32) -> [f32; 3]`:
   - Normalize height to [0, 1] range: `t = (height / height_scale + 1.0) / 2.0` (noise output is approx [-1, 1])
   - Low (t < 0.3): green (0.2, 0.6, 0.15)
   - Mid (0.3..0.7): brown (0.55, 0.35, 0.15)
   - High (t > 0.7): white (0.9, 0.9, 0.85)
   - Interpolate (lerp) at boundaries for smooth transitions
5. Implement `generate_terrain(config: &TerrainConfig) -> TerrainMesh`:
   - Create `noise::Fbm::<noise::Perlin>` with seed, octaves, frequency
   - Generate height values: for each (x, z) in grid_size x grid_size:
     - Sample: `height = fbm.get([x as f64 * freq, z as f64 * freq]) as f32 * height_scale`
     - World pos: `(x as f32 / grid_size as f32 * scale - scale/2, height, z as f32 / grid_size as f32 * scale - scale/2)`
     - Color from height_color()
     - Initially set normal to [0, 0, 0] (computed next)
   - Compute per-vertex normals:
     - For each cell, compute face normal via cross product of edge vectors
     - Accumulate onto each vertex of that face
     - Normalize all vertex normals at the end
   - Build index buffer: for each cell (x, z) where x < grid_size-1 and z < grid_size-1:
     - i = z * grid_size + x
     - Triangle 1: [i, i + grid_size, i + 1]
     - Triangle 2: [i + 1, i + grid_size, i + grid_size + 1]
6. Add unit tests:
   - `test_terrain_mesh_size`: generate with grid_size=128, assert vertices.len() == 16384, indices.len() == 96774 (127*127*6)
   - `test_terrain_normals_nonzero`: all normals have length > 0.5
   - `test_height_color_low`: height near 0 produces greenish color
7. Add `pub mod terrain;` to main.rs

## Task 7: Create terrain.wgsl shader
- **Files**: gpu-graphics-demo/shaders/terrain.wgsl
- **Depends on**: 1
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo check`

### Steps
1. Create `shaders/terrain.wgsl` with the exact shader from the design doc:
   - Uniform structs: CameraUniform (view_proj mat4x4), LightUniform (direction vec4, color vec4)
   - Bind group 0: binding 0 = camera, binding 1 = light
   - VertexInput: location 0 = position vec3, location 1 = normal vec3, location 2 = color vec3
   - VertexOutput: builtin position = clip_position vec4, location 0 = world_normal vec3, location 1 = color vec3
   - vs_main: transform position by view_proj, pass through normal and color
   - fs_main: ambient (0.15) + diffuse lighting from directional light. `dot(normal, -light_dir)`. Final color = vertex_color * brightness * light_color
2. Note: This file is loaded by renderer.rs via `include_str!("../shaders/terrain.wgsl")`. cargo check in renderer.rs will validate the path exists.

## Task 8: Implement camera.rs -- Camera, Projection, CameraController
- **Files**: gpu-graphics-demo/src/camera.rs
- **Depends on**: 1
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo test --lib test_camera`

### Steps
1. Create `src/camera.rs` with Camera struct:
   ```rust
   use glam::{Mat4, Vec3};

   pub struct Camera {
       pub position: Vec3,
       pub yaw: f32,    // radians
       pub pitch: f32,  // radians
   }
   ```
2. Implement Camera methods:
   - `new()`: position (50.0, 30.0, 50.0), yaw = -std::f32::consts::FRAC_PI_4, pitch = -0.3
   - `view_matrix(&self) -> Mat4`: compute forward direction from yaw/pitch, use `Mat4::look_to_rh(self.position, forward, Vec3::Y)`
   - Forward direction (for look): `Vec3::new(yaw.cos() * pitch.cos(), pitch.sin(), yaw.sin() * pitch.cos()).normalize()`
   - `forward(&self) -> Vec3`: movement forward on XZ plane: `Vec3::new(yaw.cos(), 0.0, yaw.sin()).normalize()`
   - `right(&self) -> Vec3`: `Vec3::new(-yaw.sin(), 0.0, yaw.cos()).normalize()`
3. Implement Projection struct:
   ```rust
   pub struct Projection {
       pub aspect: f32,
       pub fovy: f32,
       pub znear: f32,
       pub zfar: f32,
   }
   ```
4. Implement Projection methods:
   - `new(width: u32, height: u32)`: fovy = PI/4 (45 deg), znear = 0.1, zfar = 500.0, aspect = width/height
   - `resize(&mut self, width: u32, height: u32)`: update aspect ratio
   - `projection_matrix(&self) -> Mat4`: `Mat4::perspective_rh(self.fovy, self.aspect, self.znear, self.zfar)`
5. Implement CameraController struct:
   ```rust
   pub struct CameraController {
       speed: f32,
       sensitivity: f32,
       forward_pressed: bool,
       backward_pressed: bool,
       left_pressed: bool,
       right_pressed: bool,
   }
   ```
6. Implement CameraController methods:
   - `new(speed: f32, sensitivity: f32)`: store params, all keys false
   - `process_keyboard(&mut self, key: winit::keyboard::KeyCode, state: winit::event::ElementState) -> bool`: map W/S/A/D to forward/backward/left/right, set bool from Pressed/Released state
   - `process_mouse(&mut self, camera: &mut Camera, dx: f64, dy: f64)`: update camera.yaw += dx * sensitivity, camera.pitch -= dy * sensitivity, clamp pitch to [-89deg, 89deg] in radians
   - `update_camera(&self, camera: &mut Camera, dt: f32)`: move camera based on pressed keys: forward/backward along camera.forward(), left/right along camera.right(), scaled by speed * dt
7. Add unit tests:
   - `test_camera_initial_position`: camera.position.y > 0 (above terrain)
   - `test_projection_aspect`: Projection::new(800, 600).aspect approx 800.0/600.0
   - `test_pitch_clamp`: process_mouse with extreme dy, verify pitch stays in bounds
   - `test_view_matrix_deterministic`: same camera -> same matrix
8. Add `pub mod camera;` to main.rs

## Task 9: Implement app.rs -- ApplicationHandler wiring
- **Files**: gpu-graphics-demo/src/app.rs
- **Depends on**: 2, 3, 4, 5, 6, 7, 8
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo check`

### Steps
1. Create `src/app.rs` with App struct:
   ```rust
   use std::sync::Arc;
   use winit::application::ApplicationHandler;
   use winit::event::*;
   use winit::event_loop::ActiveEventLoop;
   use winit::window::{Window, WindowId};
   use crate::{renderer::Renderer, camera::{Camera, Projection, CameraController}, terrain};

   pub struct App<'a> {
       window: Option<Arc<Window>>,
       renderer: Option<Renderer<'a>>,
       camera: Camera,
       projection: Projection,
       camera_controller: CameraController,
       last_frame_time: std::time::Instant,
       mouse_captured: bool,
   }
   ```
2. Implement `App::new()`:
   - All Options as None
   - Camera::new()
   - Projection::new(800, 600) (placeholder, updated in resumed)
   - CameraController::new(20.0, 0.003)
   - last_frame_time = Instant::now()
   - mouse_captured = false
3. Implement `ApplicationHandler for App<'_>`:
   - `resumed(&mut self, event_loop: &ActiveEventLoop)`:
     - Create window: `event_loop.create_window(Window::default_attributes().with_title("GPU Graphics Demo").with_inner_size(winit::dpi::LogicalSize::new(800, 600)))`
     - Wrap in Arc
     - Generate terrain: `terrain::generate_terrain(&terrain::TerrainConfig::default())`
     - Create renderer: `pollster::block_on(Renderer::new(window.clone(), &mesh.vertices, &mesh.indices))`
     - Update projection with actual window inner_size
     - Store window and renderer
     - Request redraw
   - `window_event(...)`:
     - CloseRequested -> event_loop.exit()
     - KeyboardInput:
       - Escape (pressed) -> release mouse capture (set_cursor_visible(true), set CursorGrabMode::None), set mouse_captured = false
       - Otherwise -> camera_controller.process_keyboard(key, state)
     - Resized(new_size) -> renderer.resize(new_size), projection.resize(new_size.width, new_size.height)
     - MouseInput (Left, Pressed) -> capture mouse (set_cursor_grab(CursorGrabMode::Confined or Locked), set_cursor_visible(false)), set mouse_captured = true
     - RedrawRequested:
       - Compute dt: elapsed since last_frame_time, clamp to max 0.1s
       - Update last_frame_time
       - camera_controller.update_camera(&mut camera, dt)
       - renderer.update_camera(&camera.view_matrix(), &projection.projection_matrix())
       - Match renderer.render():
         - Ok(()) -> fine
         - Err(SurfaceError::Lost) -> renderer.resize(renderer.size())
         - Err(SurfaceError::OutOfMemory) -> event_loop.exit()
         - Err(e) -> log::error, skip frame
       - window.request_redraw()
   - `device_event(...)`:
     - DeviceEvent::MouseMotion { delta: (dx, dy) } when mouse_captured:
       - camera_controller.process_mouse(&mut camera, dx, dy)
4. Add `pub mod app;` to main.rs

## Task 10: Implement main.rs -- entry point and event loop
- **Files**: gpu-graphics-demo/src/main.rs
- **Depends on**: 9
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo check`

### Steps
1. Replace the stub main.rs with full implementation:
   ```rust
   mod app;
   mod camera;
   mod renderer;
   mod terrain;
   mod texture;
   mod uniforms;
   mod vertex;

   fn main() {
       env_logger::init();
       let event_loop = winit::event_loop::EventLoop::new().unwrap();
       event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);
       let mut app = app::App::new();
       event_loop.run_app(&mut app).unwrap();
   }
   ```
2. Ensure all mod declarations are present and in correct order
3. Verify with `cargo check` that all modules resolve and compile

## Task 11: Quality checkpoint -- full build and lint
- **Files**: (none -- verification only)
- **Depends on**: 10
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo fmt --check && cargo clippy -- -D warnings && cargo build`

### Steps
1. Run `cargo fmt --check` -- fix any formatting issues in all .rs files
2. Run `cargo clippy -- -D warnings` -- fix any lint warnings
3. Run `cargo build` -- verify full release-quality build succeeds
4. Run `cargo test` -- verify all unit tests pass (vertex size, uniform sizes, terrain mesh, camera math)
5. Fix any issues found, re-run until all commands pass

## Task 12: Integration verification -- run the demo
- **Files**: (none -- verification only)
- **Depends on**: 11
- **Verify**: `cd /Users/patrickkavanagh/parallel_ralph/gpu-graphics-demo && cargo build && timeout 5 cargo run 2>&1; test $? -eq 124 -o $? -eq 0 && echo "PASS: app launched successfully"`

### Steps
1. Run `cargo build` to ensure clean build
2. Run `cargo run` with a timeout to verify:
   - Binary launches without panic
   - Window creation succeeds (wgpu adapter found, surface created)
   - The process runs for a few seconds without crashing (timeout kills it)
3. Run `cargo test` to verify all unit tests still pass
4. Verify with `cargo fmt --check && cargo clippy -- -D warnings` one final time
