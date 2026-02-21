import type { ChartContext, Chart } from '../types';
import { WORKGROUP_SIZE, DEFAULT_HEATMAP_GRID_SIZE } from '../types';
import type { RingBuffer } from '../gpu/ring-buffer';
import { createBuffer } from '../gpu/buffers';
import heatmapBinShader from '../compute/heatmap-bin.wgsl';
import heatmapRenderShader from './heatmap.wgsl';

export interface HeatmapConfig {
  ctx: ChartContext;
  ringBuffer: RingBuffer; // channelCount: 2 (x, y pairs)
  gridSize?: number;       // default 32
}

export function createHeatmap(config: HeatmapConfig): Chart {
  const { ctx, ringBuffer } = config;
  const { device, gpuContext, format } = ctx;
  const gridSize = config.gridSize ?? DEFAULT_HEATMAP_GRID_SIZE;

  let dirty = false;

  // Bin buffer: gridSize * gridSize u32 cells
  const binBuffer = createBuffer(
    device,
    gridSize * gridSize * 4,
    GPUBufferUsage.STORAGE,
    'heatmap-bins',
  );

  // HeatmapParams uniform: { gridSize: u32, _pad1-3: u32 }
  const paramsBuffer = createBuffer(
    device,
    16,
    GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    'heatmap-params',
  );

  // Write gridSize into params (only needs to happen once)
  const paramsData = new Uint32Array([gridSize, 0, 0, 0]);
  device.queue.writeBuffer(paramsBuffer, 0, paramsData);

  // Compute pipelines from same WGSL module with different entry points
  const computeBindGroupLayout = device.createBindGroupLayout({
    label: 'heatmap-compute-group1',
    entries: [
      { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
      { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'storage' } },
    ],
  });

  const computePipelineLayout = device.createPipelineLayout({
    label: 'heatmap-compute-layout',
    bindGroupLayouts: [ringBuffer.bindGroupLayout, computeBindGroupLayout],
  });

  const computeModule = device.createShaderModule({
    label: 'heatmap-bin-shader',
    code: heatmapBinShader,
  });

  const clearPipeline = device.createComputePipeline({
    label: 'heatmap-clear',
    layout: computePipelineLayout,
    compute: { module: computeModule, entryPoint: 'clear' },
  });

  const binPipeline = device.createComputePipeline({
    label: 'heatmap-bin',
    layout: computePipelineLayout,
    compute: { module: computeModule, entryPoint: 'bin' },
  });

  const computeBindGroup = device.createBindGroup({
    label: 'heatmap-compute-bg1',
    layout: computeBindGroupLayout,
    entries: [
      { binding: 0, resource: { buffer: paramsBuffer } },
      { binding: 1, resource: { buffer: binBuffer } },
    ],
  });

  // Render pipeline
  const renderBindGroupLayout = device.createBindGroupLayout({
    label: 'heatmap-render-layout',
    entries: [
      { binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: 'read-only-storage' } },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT | GPUShaderStage.VERTEX, buffer: { type: 'uniform' } },
    ],
  });

  const renderPipelineLayout = device.createPipelineLayout({
    label: 'heatmap-render-pipeline-layout',
    bindGroupLayouts: [renderBindGroupLayout],
  });

  const renderModule = device.createShaderModule({
    label: 'heatmap-render-shader',
    code: heatmapRenderShader,
  });

  const renderPipeline = device.createRenderPipeline({
    label: 'heatmap-render',
    layout: renderPipelineLayout,
    vertex: {
      module: renderModule,
      entryPoint: 'vs_main',
    },
    fragment: {
      module: renderModule,
      entryPoint: 'fs_main',
      targets: [{ format }],
    },
    primitive: { topology: 'triangle-list' },
  });

  // HeatmapUniforms: { gridSize: u32, maxCount: u32, _pad1: u32, _pad2: u32 }
  const renderUniformBuffer = createBuffer(
    device,
    16,
    GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    'heatmap-render-uniforms',
  );

  const renderBindGroup = device.createBindGroup({
    label: 'heatmap-render-bg',
    layout: renderBindGroupLayout,
    entries: [
      { binding: 0, resource: { buffer: binBuffer } },
      { binding: 1, resource: { buffer: renderUniformBuffer } },
    ],
  });

  function frame(encoder: GPUCommandEncoder): boolean {
    if (ringBuffer.count < 1) {
      return false;
    }

    // Dispatch clear: zero all bins
    const clearPass = encoder.beginComputePass({ label: 'heatmap-clear' });
    clearPass.setPipeline(clearPipeline);
    clearPass.setBindGroup(0, ringBuffer.bindGroup);
    clearPass.setBindGroup(1, computeBindGroup);
    clearPass.dispatchWorkgroups(Math.ceil((gridSize * gridSize) / WORKGROUP_SIZE));
    clearPass.end();

    // Dispatch bin: scatter 2D points into grid
    const binPass = encoder.beginComputePass({ label: 'heatmap-bin' });
    binPass.setPipeline(binPipeline);
    binPass.setBindGroup(0, ringBuffer.bindGroup);
    binPass.setBindGroup(1, computeBindGroup);
    binPass.dispatchWorkgroups(Math.ceil(ringBuffer.count / WORKGROUP_SIZE));
    binPass.end();

    // Write render uniforms: maxCount heuristic
    const maxCount = Math.max(Math.floor(ringBuffer.count / (gridSize * gridSize) * 4), 1);
    const uniformData = new Uint32Array([gridSize, maxCount, 0, 0]);
    device.queue.writeBuffer(renderUniformBuffer, 0, uniformData);

    // Render pass: full-screen quad
    const textureView = gpuContext.getCurrentTexture().createView();
    const renderPass = encoder.beginRenderPass({
      label: 'heatmap-render',
      colorAttachments: [{
        view: textureView,
        clearValue: { r: 0.1, g: 0.1, b: 0.15, a: 1.0 },
        loadOp: 'clear',
        storeOp: 'store',
      }],
    });
    renderPass.setPipeline(renderPipeline);
    renderPass.setBindGroup(0, renderBindGroup);
    renderPass.draw(6);
    renderPass.end();

    return true;
  }

  function markDirty(): void {
    dirty = true;
  }

  function destroy(): void {
    binBuffer.destroy();
    paramsBuffer.destroy();
    renderUniformBuffer.destroy();
  }

  return { frame, markDirty, destroy };
}
