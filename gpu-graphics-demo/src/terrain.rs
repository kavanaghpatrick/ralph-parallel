use crate::vertex::Vertex;
use noise::{Fbm, MultiFractal, NoiseFn, Perlin};

pub struct TerrainMesh {
    pub vertices: Vec<Vertex>,
    pub indices: Vec<u32>,
}

pub struct TerrainConfig {
    pub grid_size: u32,
    pub scale: f32,
    pub height_scale: f32,
    pub seed: u32,
    pub octaves: usize,
    pub frequency: f64,
}

impl Default for TerrainConfig {
    fn default() -> Self {
        Self {
            grid_size: 128,
            scale: 100.0,
            height_scale: 15.0,
            seed: 42,
            octaves: 6,
            frequency: 0.02,
        }
    }
}

fn height_color(height: f32, height_scale: f32) -> [f32; 3] {
    let normalized = (height / height_scale + 1.0) * 0.5;
    let n = normalized.clamp(0.0, 1.0);

    if n < 0.3 {
        // Green (low terrain)
        [0.2, 0.6, 0.1]
    } else if n < 0.35 {
        // Lerp green -> brown
        let t = (n - 0.3) / 0.05;
        [
            0.2 + t * (0.55 - 0.2),
            0.6 + t * (0.35 - 0.6),
            0.1 + t * (0.15 - 0.1),
        ]
    } else if n < 0.65 {
        // Brown (mid terrain)
        [0.55, 0.35, 0.1]
    } else if n < 0.7 {
        // Lerp brown -> white
        let t = (n - 0.65) / 0.05;
        [
            0.55 + t * (1.0 - 0.55),
            0.35 + t * (1.0 - 0.35),
            0.1 + t * (1.0 - 0.1),
        ]
    } else {
        // White (peaks)
        [1.0, 1.0, 1.0]
    }
}

pub fn generate_terrain(config: &TerrainConfig) -> TerrainMesh {
    let fbm = Fbm::<Perlin>::new(config.seed)
        .set_octaves(config.octaves)
        .set_frequency(config.frequency);

    let grid = config.grid_size;
    let num_vertices = (grid * grid) as usize;
    let half_scale = config.scale / 2.0;

    // Generate vertices with positions, colors, and zero normals
    let mut vertices: Vec<Vertex> = Vec::with_capacity(num_vertices);
    for z in 0..grid {
        for x in 0..grid {
            let wx = (x as f32 / (grid - 1) as f32) * config.scale - half_scale;
            let wz = (z as f32 / (grid - 1) as f32) * config.scale - half_scale;
            let height = fbm.get([wx as f64, wz as f64]) as f32 * config.height_scale;
            let color = height_color(height, config.height_scale);

            vertices.push(Vertex {
                position: [wx, height, wz],
                normal: [0.0, 0.0, 0.0],
                color,
            });
        }
    }

    // Build index buffer and accumulate face normals onto vertices
    let num_cells = ((grid - 1) * (grid - 1)) as usize;
    let mut indices: Vec<u32> = Vec::with_capacity(num_cells * 6);

    for z in 0..(grid - 1) {
        for x in 0..(grid - 1) {
            let i = z * grid + x;
            let i0 = i;
            let i1 = i + grid;
            let i2 = i + 1;
            let i3 = i + 1;
            let i4 = i + grid;
            let i5 = i + grid + 1;

            indices.push(i0);
            indices.push(i1);
            indices.push(i2);
            indices.push(i3);
            indices.push(i4);
            indices.push(i5);

            // Triangle 1: i0, i1, i2
            {
                let p0 = vertices[i0 as usize].position;
                let p1 = vertices[i1 as usize].position;
                let p2 = vertices[i2 as usize].position;
                let e1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
                let e2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
                let n = [
                    e1[1] * e2[2] - e1[2] * e2[1],
                    e1[2] * e2[0] - e1[0] * e2[2],
                    e1[0] * e2[1] - e1[1] * e2[0],
                ];
                for &vi in &[i0, i1, i2] {
                    let v = &mut vertices[vi as usize];
                    v.normal[0] += n[0];
                    v.normal[1] += n[1];
                    v.normal[2] += n[2];
                }
            }

            // Triangle 2: i3, i4, i5
            {
                let p0 = vertices[i3 as usize].position;
                let p1 = vertices[i4 as usize].position;
                let p2 = vertices[i5 as usize].position;
                let e1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
                let e2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
                let n = [
                    e1[1] * e2[2] - e1[2] * e2[1],
                    e1[2] * e2[0] - e1[0] * e2[2],
                    e1[0] * e2[1] - e1[1] * e2[0],
                ];
                for &vi in &[i3, i4, i5] {
                    let v = &mut vertices[vi as usize];
                    v.normal[0] += n[0];
                    v.normal[1] += n[1];
                    v.normal[2] += n[2];
                }
            }
        }
    }

    // Normalize all vertex normals
    for v in &mut vertices {
        let len =
            (v.normal[0] * v.normal[0] + v.normal[1] * v.normal[1] + v.normal[2] * v.normal[2])
                .sqrt();
        if len > 0.0 {
            v.normal[0] /= len;
            v.normal[1] /= len;
            v.normal[2] /= len;
        }
    }

    TerrainMesh { vertices, indices }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_terrain_mesh_size() {
        let config = TerrainConfig::default();
        let mesh = generate_terrain(&config);
        assert_eq!(mesh.vertices.len(), 16384); // 128 * 128
        assert_eq!(mesh.indices.len(), 96774); // 127 * 127 * 6
    }

    #[test]
    fn test_terrain_normals_nonzero() {
        let config = TerrainConfig::default();
        let mesh = generate_terrain(&config);
        for v in &mesh.vertices {
            let len =
                (v.normal[0] * v.normal[0] + v.normal[1] * v.normal[1] + v.normal[2] * v.normal[2])
                    .sqrt();
            assert!(len > 0.5, "Normal length {} is too small", len);
        }
    }

    #[test]
    fn test_height_color_low() {
        let color = height_color(0.0, 15.0);
        // At height 0, normalized = 0.5 which is in the brown zone
        // For truly low, use negative height
        let low_color = height_color(-14.0, 15.0);
        // Should be greenish: green channel > red channel
        assert!(
            low_color[1] > low_color[0],
            "Low terrain should be greenish: {:?}",
            low_color
        );
    }
}
