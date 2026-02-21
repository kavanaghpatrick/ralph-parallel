export interface RingBufferConfig {
  device: GPUDevice;
  /** Must be power-of-2. Default 4096. */
  capacity: number;
  /** Floats per entry. 1 for scalar, 2 for x/y pairs. */
  channelCount: number;
  label?: string;
}

export interface RingBuffer {
  /** GPU storage buffer. Usage: STORAGE | COPY_DST. Size: capacity * channelCount * 4 bytes. */
  buffer: GPUBuffer;
  /**
   * Uniform buffer: [head: u32, count: u32, capacity: u32, channelCount: u32].
   * 16 bytes total. Updated on every push().
   */
  metaBuffer: GPUBuffer;
  /** Pre-built bind group layout for shaders consuming this ring buffer. */
  bindGroupLayout: GPUBindGroupLayout;
  /** Pre-built bind group with buffer @ binding(0), metaBuffer @ binding(1). */
  bindGroup: GPUBindGroup;
  /**
   * Append data to ring buffer. Wraps at capacity.
   * Calls device.queue.writeBuffer() for data + meta. No GPU readback.
   * @param data Columnar Float32Array. Length must be multiple of channelCount.
   */
  push(data: Float32Array): void;
  /** CPU-side head position (write index). */
  readonly head: number;
  /** Number of valid entries (capped at capacity). */
  readonly count: number;
  readonly capacity: number;
}

export function createRingBuffer(config: RingBufferConfig): RingBuffer {
  const { device, capacity, channelCount, label } = config;

  if (capacity <= 0 || (capacity & (capacity - 1)) !== 0) {
    throw new Error(`Ring buffer capacity must be a power of 2, got ${capacity}`);
  }

  const bufferSize = capacity * channelCount * 4;
  const buffer = device.createBuffer({
    label: label ? `${label}-data` : 'ring-data',
    size: bufferSize,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });

  const metaBuffer = device.createBuffer({
    label: label ? `${label}-meta` : 'ring-meta',
    size: 16,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const bindGroupLayout = device.createBindGroupLayout({
    label: label ? `${label}-layout` : 'ring-layout',
    entries: [
      { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
      { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
    ],
  });

  const bindGroup = device.createBindGroup({
    label: label ? `${label}-bind` : 'ring-bind',
    layout: bindGroupLayout,
    entries: [
      { binding: 0, resource: { buffer } },
      { binding: 1, resource: { buffer: metaBuffer } },
    ],
  });

  let head = 0;
  let count = 0;
  let totalWritten = 0;
  const metaArray = new Uint32Array(4);

  function push(data: Float32Array): void {
    const entries = data.length / channelCount;

    for (let i = 0; i < entries; i++) {
      const srcOffset = i * channelCount;
      const dstOffset = head * channelCount;

      device.queue.writeBuffer(
        buffer,
        dstOffset * 4,
        data.buffer,
        data.byteOffset + srcOffset * 4,
        channelCount * 4,
      );

      head = (head + 1) & (capacity - 1);
    }

    totalWritten += entries;
    count = Math.min(totalWritten, capacity);

    metaArray[0] = head;
    metaArray[1] = count;
    metaArray[2] = capacity;
    metaArray[3] = channelCount;
    device.queue.writeBuffer(metaBuffer, 0, metaArray);
  }

  return {
    buffer,
    metaBuffer,
    bindGroupLayout,
    bindGroup,
    push,
    get head() { return head; },
    get count() { return count; },
    capacity,
  };
}
