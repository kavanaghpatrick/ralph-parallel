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

  const format = navigator.gpu.getPreferredCanvasFormat();

  function setupCanvas(id: string): ChartContext {
    const canvas = document.getElementById(id) as HTMLCanvasElement;
    const gpuContext = canvas.getContext('webgpu')!;
    gpuContext.configure({ device, format, alphaMode: 'premultiplied' });
    return { device, canvas, gpuContext, format };
  }

  const lineCtx = setupCanvas('line-canvas');
  const heatCtx = setupCanvas('heatmap-canvas');
  const histCtx = setupCanvas('histogram-canvas');

  const timeSeries = createRingBuffer({ device, capacity: DEFAULT_RING_CAPACITY, channelCount: 1, label: 'time-series' });
  const scatter2D = createRingBuffer({ device, capacity: DEFAULT_RING_CAPACITY, channelCount: 2, label: 'scatter-2d' });
  const values1D = createRingBuffer({ device, capacity: DEFAULT_RING_CAPACITY, channelCount: 1, label: 'values-1d' });

  const lineChart = createLineChart({ ctx: lineCtx, ringBuffer: timeSeries });
  const heatmap = createHeatmap({ ctx: heatCtx, ringBuffer: scatter2D });
  const histogram = createHistogram({ ctx: histCtx, ringBuffer: values1D });

  let dirty = false;

  function renderFrame(): void {
    if (!dirty) return;
    const encoder = device.createCommandEncoder();
    lineChart.frame(encoder);
    heatmap.frame(encoder);
    histogram.frame(encoder);
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
