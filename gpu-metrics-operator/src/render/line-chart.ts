import type { ChartContext, Chart } from '../types';
import { WORKGROUP_SIZE, DEFAULT_EMA_ALPHA, DEFAULT_LINE_THICKNESS } from '../types';
import type { RingBuffer } from '../gpu/ring-buffer';
import { createPingPong, createBuffer } from '../gpu/buffers';
import aggregationShader from '../compute/aggregation.wgsl';
import smoothingShader from '../compute/smoothing.wgsl';
import lineChartShader from './line-chart.wgsl';

export interface LineChartConfig {
  ctx: ChartContext;
  ringBuffer: RingBuffer;
  emaAlpha?: number;
  lineThickness?: number;
}

export function createLineChart(config: LineChartConfig): Chart {
  const { ctx, ringBuffer } = config;
  const { device, gpuContext, format } = ctx;
  const alpha = config.emaAlpha ?? DEFAULT_EMA_ALPHA;
  const thickness = config.lineThickness ?? DEFAULT_LINE_THICKNESS;

  let dirty = false;

  // Aggregation pipeline -- reads ring buffer, outputs min/max/sum/count
  const aggResultBuffer = createBuffer(
    device,
    16, // 4 x f32/u32
    GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    'agg-result',
  );

  const aggModule = device.createShaderModule({ code: aggregationShader, label: 'aggregation' });
  const aggPipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: aggModule, entryPoint: 'main' },
  });

  const aggBindGroup = device.createBindGroup({
    layout: aggPipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: ringBuffer.buffer } },
      { binding: 1, resource: { buffer: ringBuffer.metaBuffer } },
    ],
  });

  const aggOutputBindGroup = device.createBindGroup({
    layout: aggPipeline.getBindGroupLayout(1),
    entries: [
      { binding: 0, resource: { buffer: aggResultBuffer } },
    ],
  });

  // Smoothing pipeline -- reads ring buffer + alpha, writes smoothed output
  const smoothParamsBuffer = createBuffer(
    device,
    16, // SmoothParams: alpha(f32) + count(u32) + 2 padding u32
    GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    'smooth-params',
  );

  const pingPong = createPingPong({
    device,
    size: ringBuffer.capacity * 4, // f32 per entry
    label: 'line-smoothed',
  });

  const smoothModule = device.createShaderModule({ code: smoothingShader, label: 'smoothing' });
  const smoothPipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: smoothModule, entryPoint: 'main' },
  });

  const smoothRingBindGroup = device.createBindGroup({
    layout: smoothPipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: ringBuffer.buffer } },
      { binding: 1, resource: { buffer: ringBuffer.metaBuffer } },
    ],
  });

  // We need to create smoothing output bind groups for each ping-pong side
  // since writeBuffer alternates
  function createSmoothOutputBindGroup(writeBuffer: GPUBuffer): GPUBindGroup {
    return device.createBindGroup({
      layout: smoothPipeline.getBindGroupLayout(1),
      entries: [
        { binding: 0, resource: { buffer: smoothParamsBuffer } },
        { binding: 1, resource: { buffer: writeBuffer } },
      ],
    });
  }

  // Line render pipeline
  const lineUniformBuffer = createBuffer(
    device,
    16, // LineUniforms: pointCount(u32) + thickness(f32) + minVal(f32) + maxVal(f32)
    GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    'line-uniforms',
  );

  const lineModule = device.createShaderModule({ code: lineChartShader, label: 'line-chart' });
  const renderPipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: {
      module: lineModule,
      entryPoint: 'vs_main',
    },
    fragment: {
      module: lineModule,
      entryPoint: 'fs_main',
      targets: [{ format }],
    },
    primitive: {
      topology: 'triangle-list',
    },
  });

  // Render bind groups also need to track which ping-pong read buffer is active
  function createRenderBindGroup(readBuffer: GPUBuffer): GPUBindGroup {
    return device.createBindGroup({
      layout: renderPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: readBuffer } },
        { binding: 1, resource: { buffer: lineUniformBuffer } },
      ],
    });
  }

  function frame(encoder: GPUCommandEncoder): boolean {
    const count = ringBuffer.count;
    if (count < 2) {
      return false;
    }

    // 1. Dispatch aggregation compute
    const aggPass = encoder.beginComputePass({ label: 'line-aggregation' });
    aggPass.setPipeline(aggPipeline);
    aggPass.setBindGroup(0, aggBindGroup);
    aggPass.setBindGroup(1, aggOutputBindGroup);
    aggPass.dispatchWorkgroups(Math.ceil(count / WORKGROUP_SIZE));
    aggPass.end();

    // 2. Write smoothing params and dispatch
    const smoothParamsData = new ArrayBuffer(16);
    const smoothView = new DataView(smoothParamsData);
    smoothView.setFloat32(0, alpha, true);
    smoothView.setUint32(4, count, true);
    smoothView.setUint32(8, 0, true);
    smoothView.setUint32(12, 0, true);
    device.queue.writeBuffer(smoothParamsBuffer, 0, smoothParamsData);

    const smoothOutputBG = createSmoothOutputBindGroup(pingPong.writeBuffer);

    const smoothPass = encoder.beginComputePass({ label: 'line-smoothing' });
    smoothPass.setPipeline(smoothPipeline);
    smoothPass.setBindGroup(0, smoothRingBindGroup);
    smoothPass.setBindGroup(1, smoothOutputBG);
    smoothPass.dispatchWorkgroups(1);
    smoothPass.end();

    // 3. Write line uniforms (POC: hardcoded minVal=0, maxVal=1)
    const lineUniformData = new ArrayBuffer(16);
    const lineView = new DataView(lineUniformData);
    lineView.setUint32(0, count, true);
    lineView.setFloat32(4, thickness, true);
    lineView.setFloat32(8, 0.0, true);  // minVal
    lineView.setFloat32(12, 1.0, true); // maxVal
    device.queue.writeBuffer(lineUniformBuffer, 0, lineUniformData);

    // 4. Render pass
    const renderBG = createRenderBindGroup(pingPong.readBuffer);
    const textureView = gpuContext.getCurrentTexture().createView();

    const renderPass = encoder.beginRenderPass({
      label: 'line-render',
      colorAttachments: [{
        view: textureView,
        clearValue: { r: 0.1, g: 0.1, b: 0.15, a: 1.0 },
        loadOp: 'clear',
        storeOp: 'store',
      }],
    });
    renderPass.setPipeline(renderPipeline);
    renderPass.setBindGroup(0, renderBG);
    renderPass.draw(6 * (count - 1));
    renderPass.end();

    // 5. Swap ping-pong for next frame
    pingPong.swap();

    return true;
  }

  function markDirty(): void {
    dirty = true;
  }

  function destroy(): void {
    aggResultBuffer.destroy();
    smoothParamsBuffer.destroy();
    lineUniformBuffer.destroy();
    pingPong.writeBuffer.destroy();
    pingPong.readBuffer.destroy();
  }

  return { frame, markDirty, destroy };
}
