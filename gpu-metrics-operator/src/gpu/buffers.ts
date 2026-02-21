export interface PingPongConfig {
  device: GPUDevice;
  /** Size in bytes. */
  size: number;
  label?: string;
}

export interface PingPongBuffers {
  /** Buffer that compute writes to this frame. Usage: STORAGE | VERTEX. */
  writeBuffer: GPUBuffer;
  /** Buffer that render reads from this frame. Usage: STORAGE | VERTEX. */
  readBuffer: GPUBuffer;
  /** Swap read/write roles. Call once per frame after submit. */
  swap(): void;
}

/** Create a pair of STORAGE | VERTEX buffers for ping-pong. */
export function createPingPong(config: PingPongConfig): PingPongBuffers {
  const { device, size, label } = config;

  const bufA = device.createBuffer({
    label: label ? `${label}-A` : 'ping-pong-A',
    size,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.VERTEX,
  });

  const bufB = device.createBuffer({
    label: label ? `${label}-B` : 'ping-pong-B',
    size,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.VERTEX,
  });

  let current = 0;

  return {
    get writeBuffer() { return current === 0 ? bufA : bufB; },
    get readBuffer() { return current === 0 ? bufB : bufA; },
    swap() { current = 1 - current; },
  };
}

/** Create a GPU buffer with arbitrary usage flags. */
export function createBuffer(
  device: GPUDevice,
  size: number,
  usage: GPUBufferUsageFlags,
  label?: string,
): GPUBuffer {
  return device.createBuffer({ label, size, usage });
}
