use std::sync::Arc;
use std::time::Instant;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::{DeviceEvent, DeviceId, ElementState, KeyEvent, WindowEvent};
use winit::event_loop::ActiveEventLoop;
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{CursorGrabMode, Window, WindowId};

use crate::camera::{Camera, CameraController, Projection};
use crate::renderer::Renderer;
use crate::terrain;

pub struct App<'a> {
    window: Option<Arc<Window>>,
    renderer: Option<Renderer<'a>>,
    camera: Camera,
    projection: Projection,
    camera_controller: CameraController,
    last_frame_time: Instant,
    mouse_captured: bool,
}

impl App<'_> {
    pub fn new() -> Self {
        Self {
            window: None,
            renderer: None,
            camera: Camera::new(),
            projection: Projection::new(800, 600),
            camera_controller: CameraController::new(20.0, 0.003),
            last_frame_time: Instant::now(),
            mouse_captured: false,
        }
    }
}

impl ApplicationHandler for App<'_> {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        let attrs = Window::default_attributes()
            .with_title("GPU Graphics Demo")
            .with_inner_size(LogicalSize::new(800, 600));
        let window = Arc::new(event_loop.create_window(attrs).unwrap());

        let mesh = terrain::generate_terrain(&terrain::TerrainConfig::default());
        self.renderer = Some(pollster::block_on(Renderer::new(
            window.clone(),
            &mesh.vertices,
            &mesh.indices,
        )));

        let size = window.inner_size();
        self.projection.resize(size.width, size.height);
        self.window = Some(window);

        if let Some(window) = &self.window {
            window.request_redraw();
        }
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),

            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(key),
                        state,
                        ..
                    },
                ..
            } => {
                if key == KeyCode::Escape && state == ElementState::Pressed {
                    self.mouse_captured = false;
                    if let Some(window) = &self.window {
                        let _ = window.set_cursor_grab(CursorGrabMode::None);
                        window.set_cursor_visible(true);
                    }
                } else {
                    self.camera_controller.process_keyboard(key, state);
                }
            }

            WindowEvent::Resized(new_size) => {
                if let Some(renderer) = &mut self.renderer {
                    renderer.resize(new_size);
                }
                self.projection.resize(new_size.width, new_size.height);
            }

            WindowEvent::MouseInput {
                state: ElementState::Pressed,
                button: winit::event::MouseButton::Left,
                ..
            } => {
                self.mouse_captured = true;
                if let Some(window) = &self.window {
                    let _ = window
                        .set_cursor_grab(CursorGrabMode::Confined)
                        .or_else(|_| window.set_cursor_grab(CursorGrabMode::Locked));
                    window.set_cursor_visible(false);
                }
            }

            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                let dt = (now - self.last_frame_time).as_secs_f32().min(0.1);
                self.last_frame_time = now;

                self.camera_controller.update_camera(&mut self.camera, dt);

                if let Some(renderer) = &mut self.renderer {
                    let view = self.camera.view_matrix();
                    let proj = self.projection.projection_matrix();
                    renderer.update_camera(&view, &proj);

                    match renderer.render() {
                        Ok(()) => {}
                        Err(wgpu::SurfaceError::Lost) => {
                            let size = renderer.size();
                            renderer.resize(size);
                        }
                        Err(wgpu::SurfaceError::OutOfMemory) => {
                            log::error!("Out of GPU memory");
                            event_loop.exit();
                        }
                        Err(e) => {
                            log::error!("Render error: {:?}", e);
                        }
                    }
                }

                if let Some(window) = &self.window {
                    window.request_redraw();
                }
            }

            _ => {}
        }
    }

    fn device_event(
        &mut self,
        _event_loop: &ActiveEventLoop,
        _device_id: DeviceId,
        event: DeviceEvent,
    ) {
        if self.mouse_captured {
            if let DeviceEvent::MouseMotion { delta: (dx, dy) } = event {
                self.camera_controller
                    .process_mouse(&mut self.camera, dx, dy);
            }
        }
    }
}
