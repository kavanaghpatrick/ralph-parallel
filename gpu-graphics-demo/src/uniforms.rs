use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct CameraUniform {
    pub view_proj: [[f32; 4]; 4],
}

impl CameraUniform {
    pub fn new() -> Self {
        Self {
            view_proj: glam::Mat4::IDENTITY.to_cols_array_2d(),
        }
    }

    pub fn update_view_proj(&mut self, view: &glam::Mat4, proj: &glam::Mat4) {
        self.view_proj = (*proj * *view).to_cols_array_2d();
    }
}

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct LightUniform {
    pub direction: [f32; 4],
    pub color: [f32; 4],
}

impl LightUniform {
    pub fn new() -> Self {
        let dir = glam::Vec3::new(-0.5, -1.0, -0.3).normalize();
        Self {
            direction: [dir.x, dir.y, dir.z, 0.0],
            color: [1.0, 1.0, 1.0, 0.0],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_camera_uniform_size() {
        assert_eq!(std::mem::size_of::<CameraUniform>(), 64);
    }

    #[test]
    fn test_light_uniform_size() {
        assert_eq!(std::mem::size_of::<LightUniform>(), 32);
    }
}
