import { initGPU, showFallback } from './gpu/device';
import { createRingBuffer } from './gpu/ring-buffer';
import { createLineChart } from './render/line-chart';
import { createHeatmap } from './render/heatmap';
import { createHistogram } from './render/histogram';
import { createGenerator } from './data/generator';
import {
  DEFAULT_RING_CAPACITY,
  DEFAULT_DATA_INTERVAL_MS,
  DEFAULT_BATCH_SIZE,
} from './types';
import type { ChartContext } from './types';

async function main(): Promise<void> {
  const maybeDevice = await initGPU();
  if (!maybeDevice) {
    const fallback = document.getElementById('fallback');
    if (fallback) showFallback(fallback, 'WebGPU initialization failed.');
    return;
  }
  const device: GPUDevice = maybeDevice;

  device.lost.then((info) => {
    console.error('WebGPU device lost:', info.message);
    const fallback = document.getElementById('fallback');
    if (fallback) showFallback(fallback, `GPU device lost: ${info.message}`);
  });

  const format = navigator.gpu.getPreferredCanvasFormat();

  function setupCanvas(id: string): ChartContext | null {
    const canvas = document.getElementById(id) as HTMLCanvasElement | null;
    if (!canvas) {
      console.error(`Canvas element #${id} not found`);
      return null;
    }
    const gpuContext = canvas.getContext('webgpu');
    if (!gpuContext) {
      console.error(`Failed to get WebGPU context for #${id}`);
      return null;
    }
    gpuContext.configure({ device, format, alphaMode: 'premultiplied' });
    return { device, canvas, gpuContext, format };
  }

  const lineCtx = setupCanvas('line-canvas');
  const heatCtx = setupCanvas('heatmap-canvas');
  const histCtx = setupCanvas('histogram-canvas');

  const timeSeries = createRingBuffer({ device, capacity: DEFAULT_RING_CAPACITY, channelCount: 1, label: 'time-series' });
  const scatter2D = createRingBuffer({ device, capacity: DEFAULT_RING_CAPACITY, channelCount: 2, label: 'scatter-2d' });
  const values1D = createRingBuffer({ device, capacity: DEFAULT_RING_CAPACITY, channelCount: 1, label: 'values-1d' });

  const charts: import('./types').Chart[] = [];
  if (lineCtx) charts.push(createLineChart({ ctx: lineCtx, ringBuffer: timeSeries }));
  if (heatCtx) charts.push(createHeatmap({ ctx: heatCtx, ringBuffer: scatter2D }));
  if (histCtx) charts.push(createHistogram({ ctx: histCtx, ringBuffer: values1D }));

  let dirty = false;

  function renderFrame(): void {
    if (!dirty) return;
    const encoder = device.createCommandEncoder();
    for (const chart of charts) chart.frame(encoder);
    device.queue.submit([encoder.finish()]);
    dirty = false;
  }

  const generator = createGenerator(
    { interval: DEFAULT_DATA_INTERVAL_MS, batchSize: DEFAULT_BATCH_SIZE },
    { timeSeries, scatter2D, values1D },
    () => {
      dirty = true;
      requestAnimationFrame(renderFrame);
    },
  );

  generator.start();
}

main();
