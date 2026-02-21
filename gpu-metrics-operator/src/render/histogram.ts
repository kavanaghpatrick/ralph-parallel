import type { ChartContext, Chart } from '../types';
import { WORKGROUP_SIZE, DEFAULT_HISTOGRAM_BINS } from '../types';
import type { RingBuffer } from '../gpu/ring-buffer';
import { createBuffer } from '../gpu/buffers';
import histogramBinShader from '../compute/histogram-bin.wgsl';
import histogramRenderShader from './histogram.wgsl';

export interface HistogramConfig {
  ctx: ChartContext;
  ringBuffer: RingBuffer;
  numBins?: number;
}

export function createHistogram(config: HistogramConfig): Chart {
  const { ctx, ringBuffer } = config;
  const { device, gpuContext, format } = ctx;
  const numBins = config.numBins ?? DEFAULT_HISTOGRAM_BINS;

  let dirty = false;

  // Bin buffer: numBins * 4 bytes (u32 per bin), usage STORAGE
  const binBuffer = createBuffer(
    device,
    numBins * 4,
    GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    'histogram-bins',
  );

  // HistParams uniform (16 bytes): { numBins, _pad1, _pad2, _pad3 }
  const paramsBuffer = createBuffer(
    device,
    16,
    GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    'histogram-params',
  );

  // HistUniforms for render (16 bytes): { numBins, maxCount, _pad1, _pad2 }
  const renderUniformsBuffer = createBuffer(
    device,
    16,
    GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    'histogram-render-uniforms',
  );

  // Compute module + pipelines
  const computeModule = device.createShaderModule({
    label: 'histogram-bin',
    code: histogramBinShader,
  });

  const computeBindGroupLayout = device.createBindGroupLayout({
    label: 'histogram-compute-group1',
    entries: [
      { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
      { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'storage' } },
    ],
  });

  const computePipelineLayout = device.createPipelineLayout({
    label: 'histogram-compute',
    bindGroupLayouts: [ringBuffer.bindGroupLayout, computeBindGroupLayout],
  });

  const clearPipeline = device.createComputePipeline({
    label: 'histogram-clear',
    layout: computePipelineLayout,
    compute: { module: computeModule, entryPoint: 'clear' },
  });

  const binPipeline = device.createComputePipeline({
    label: 'histogram-bin',
    layout: computePipelineLayout,
    compute: { module: computeModule, entryPoint: 'bin' },
  });

  const computeBindGroup = device.createBindGroup({
    label: 'histogram-compute-group1',
    layout: computeBindGroupLayout,
    entries: [
      { binding: 0, resource: { buffer: paramsBuffer } },
      { binding: 1, resource: { buffer: binBuffer } },
    ],
  });

  // Render pipeline
  const renderModule = device.createShaderModule({
    label: 'histogram-render',
    code: histogramRenderShader,
  });

  const renderBindGroupLayout = device.createBindGroupLayout({
    label: 'histogram-render-group0',
    entries: [
      { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'read-only-storage' } },
      { binding: 1, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
    ],
  });

  const renderPipelineLayout = device.createPipelineLayout({
    label: 'histogram-render',
    bindGroupLayouts: [renderBindGroupLayout],
  });

  const renderPipeline = device.createRenderPipeline({
    label: 'histogram-render',
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

  const renderBindGroup = device.createBindGroup({
    label: 'histogram-render-group0',
    layout: renderBindGroupLayout,
    entries: [
      { binding: 0, resource: { buffer: binBuffer } },
      { binding: 1, resource: { buffer: renderUniformsBuffer } },
    ],
  });

  // Write initial params
  const paramsData = new Uint32Array([numBins, 0, 0, 0]);
  device.queue.writeBuffer(paramsBuffer, 0, paramsData);

  function frame(encoder: GPUCommandEncoder): boolean {
    if (ringBuffer.count < 1) {
      return false;
    }

    // Write HistParams
    const params = new Uint32Array([numBins, 0, 0, 0]);
    device.queue.writeBuffer(paramsBuffer, 0, params);

    // Compute pass: clear bins then bin data
    const computePass = encoder.beginComputePass({ label: 'histogram-compute' });

    // Clear
    computePass.setPipeline(clearPipeline);
    computePass.setBindGroup(0, ringBuffer.bindGroup);
    computePass.setBindGroup(1, computeBindGroup);
    computePass.dispatchWorkgroups(Math.ceil(numBins / WORKGROUP_SIZE));

    // Bin
    computePass.setPipeline(binPipeline);
    computePass.setBindGroup(0, ringBuffer.bindGroup);
    computePass.setBindGroup(1, computeBindGroup);
    computePass.dispatchWorkgroups(Math.ceil(ringBuffer.count / WORKGROUP_SIZE));

    computePass.end();

    // Write render uniforms: { numBins, maxCount, _pad1, _pad2 }
    const maxCount = Math.max(Math.floor(ringBuffer.count / numBins) * 3, 1);
    const renderUniforms = new Uint32Array([numBins, maxCount, 0, 0]);
    device.queue.writeBuffer(renderUniformsBuffer, 0, renderUniforms);

    // Render pass: instanced bar chart
    const textureView = gpuContext.getCurrentTexture().createView();
    const renderPass = encoder.beginRenderPass({
      label: 'histogram-render',
      colorAttachments: [{
        view: textureView,
        clearValue: { r: 0.1, g: 0.1, b: 0.15, a: 1.0 },
        loadOp: 'clear',
        storeOp: 'store',
      }],
    });

    renderPass.setPipeline(renderPipeline);
    renderPass.setBindGroup(0, renderBindGroup);
    renderPass.draw(6, numBins);
    renderPass.end();

    return true;
  }

  function markDirty(): void {
    dirty = true;
  }

  function destroy(): void {
    binBuffer.destroy();
    paramsBuffer.destroy();
    renderUniformsBuffer.destroy();
  }

  return { frame, markDirty, destroy };
}
