use glam::{Mat4, Vec3};

pub struct Camera {
    pub position: Vec3,
    pub yaw: f32,
    pub pitch: f32,
}

impl Camera {
    pub fn new() -> Self {
        Self {
            position: Vec3::new(50.0, 30.0, 50.0),
            yaw: -std::f32::consts::FRAC_PI_4,
            pitch: -0.3,
        }
    }

    pub fn view_matrix(&self) -> Mat4 {
        let forward = Vec3::new(
            self.yaw.cos() * self.pitch.cos(),
            self.pitch.sin(),
            self.yaw.sin() * self.pitch.cos(),
        )
        .normalize();
        Mat4::look_to_rh(self.position, forward, Vec3::Y)
    }

    pub fn forward(&self) -> Vec3 {
        Vec3::new(self.yaw.cos(), 0.0, self.yaw.sin()).normalize()
    }

    pub fn right(&self) -> Vec3 {
        Vec3::new(-self.yaw.sin(), 0.0, self.yaw.cos()).normalize()
    }
}

pub struct Projection {
    pub aspect: f32,
    pub fovy: f32,
    pub znear: f32,
    pub zfar: f32,
}

impl Projection {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            fovy: std::f32::consts::FRAC_PI_4,
            znear: 0.1,
            zfar: 500.0,
            aspect: width as f32 / height as f32,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        self.aspect = width as f32 / height as f32;
    }

    pub fn projection_matrix(&self) -> Mat4 {
        Mat4::perspective_rh(self.fovy, self.aspect, self.znear, self.zfar)
    }
}

pub struct CameraController {
    speed: f32,
    sensitivity: f32,
    forward_pressed: bool,
    backward_pressed: bool,
    left_pressed: bool,
    right_pressed: bool,
}

impl CameraController {
    pub fn new(speed: f32, sensitivity: f32) -> Self {
        Self {
            speed,
            sensitivity,
            forward_pressed: false,
            backward_pressed: false,
            left_pressed: false,
            right_pressed: false,
        }
    }

    pub fn process_keyboard(
        &mut self,
        key: winit::keyboard::KeyCode,
        state: winit::event::ElementState,
    ) -> bool {
        use winit::event::ElementState;
        use winit::keyboard::KeyCode;

        let pressed = state == ElementState::Pressed;
        match key {
            KeyCode::KeyW => {
                self.forward_pressed = pressed;
                true
            }
            KeyCode::KeyS => {
                self.backward_pressed = pressed;
                true
            }
            KeyCode::KeyA => {
                self.left_pressed = pressed;
                true
            }
            KeyCode::KeyD => {
                self.right_pressed = pressed;
                true
            }
            _ => false,
        }
    }

    pub fn process_mouse(&mut self, camera: &mut Camera, dx: f64, dy: f64) {
        camera.yaw += dx as f32 * self.sensitivity;
        camera.pitch -= dy as f32 * self.sensitivity;
        let max_pitch = 89.0_f32.to_radians();
        camera.pitch = camera.pitch.clamp(-max_pitch, max_pitch);
    }

    pub fn update_camera(&self, camera: &mut Camera, dt: f32) {
        let forward = camera.forward();
        let right = camera.right();
        let velocity = self.speed * dt;

        if self.forward_pressed {
            camera.position += forward * velocity;
        }
        if self.backward_pressed {
            camera.position -= forward * velocity;
        }
        if self.left_pressed {
            camera.position -= right * velocity;
        }
        if self.right_pressed {
            camera.position += right * velocity;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_camera_initial_position() {
        let camera = Camera::new();
        assert!(camera.position.y > 0.0, "Camera should start above ground");
    }

    #[test]
    fn test_projection_aspect() {
        let proj = Projection::new(800, 600);
        let expected = 800.0_f32 / 600.0;
        assert!(
            (proj.aspect - expected).abs() < 1e-6,
            "Aspect ratio should be 800/600, got {}",
            proj.aspect
        );
    }

    #[test]
    fn test_pitch_clamp() {
        let mut camera = Camera::new();
        let mut controller = CameraController::new(10.0, 0.01);

        // Extreme downward mouse movement
        controller.process_mouse(&mut camera, 0.0, 100000.0);
        let max_pitch = 89.0_f32.to_radians();
        assert!(
            camera.pitch >= -max_pitch - 1e-6,
            "Pitch {} should be >= -89 deg",
            camera.pitch.to_degrees()
        );

        // Extreme upward mouse movement
        controller.process_mouse(&mut camera, 0.0, -200000.0);
        assert!(
            camera.pitch <= max_pitch + 1e-6,
            "Pitch {} should be <= 89 deg",
            camera.pitch.to_degrees()
        );
    }

    #[test]
    fn test_view_matrix_deterministic() {
        let camera = Camera::new();
        let m1 = camera.view_matrix();
        let m2 = camera.view_matrix();
        assert_eq!(m1, m2, "Same camera should produce same view matrix");
    }
}
