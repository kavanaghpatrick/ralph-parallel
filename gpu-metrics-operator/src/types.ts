// Chart interface -- every chart module exports a factory returning this
export interface Chart {
  /** Encode compute + render passes into the given encoder. Returns true if anything was drawn. */
  frame(encoder: GPUCommandEncoder): boolean;
  /** Signal that new data arrived. Triggers next rAF. */
  markDirty(): void;
  /** Release GPU resources. */
  destroy(): void;
}

/** Passed to each chart factory function. */
export interface ChartContext {
  device: GPUDevice;
  canvas: HTMLCanvasElement;
  gpuContext: GPUCanvasContext;
  format: GPUTextureFormat;
}

// Constants (matching WGSL workgroup sizes and defaults)
export const WORKGROUP_SIZE = 64;
export const DEFAULT_RING_CAPACITY = 4096;
export const DEFAULT_HEATMAP_GRID_SIZE = 32;
export const DEFAULT_HISTOGRAM_BINS = 32;
export const DEFAULT_DATA_INTERVAL_MS = 500;
export const DEFAULT_BATCH_SIZE = 64;
export const DEFAULT_EMA_ALPHA = 0.1;
export const DEFAULT_LINE_THICKNESS = 2.0;
