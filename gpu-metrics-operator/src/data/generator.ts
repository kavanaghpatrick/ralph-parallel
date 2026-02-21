import type { RingBuffer } from '../gpu/ring-buffer';

export interface GeneratorConfig {
  interval: number;   // ms between pushes (default 500)
  batchSize: number;  // points per push (default 64)
}

export interface DataGenerator {
  start(): void;
  stop(): void;
}

/** Box-Muller transform: two uniform [0,1) → one gaussian(0, stddev). */
function gaussianNoise(stddev: number): number {
  const u1 = Math.random();
  const u2 = Math.random();
  return stddev * Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

function clamp01(v: number): number {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

export function createGenerator(
  config: GeneratorConfig,
  targets: {
    timeSeries: RingBuffer;  // 1 channel: sin(t) + noise
    scatter2D: RingBuffer;   // 2 channels: clustered (x,y) pairs
    values1D: RingBuffer;    // 1 channel: values in [0,1]
  },
  onData: () => void,
): DataGenerator {
  let timer: ReturnType<typeof setInterval> | null = null;
  let t = 0;
  let centerX = 0.5;
  let centerY = 0.5;

  function tick(): void {
    const { batchSize } = config;
    const ts = new Float32Array(batchSize);
    const sc = new Float32Array(batchSize * 2);
    const v1 = new Float32Array(batchSize);

    for (let i = 0; i < batchSize; i++) {
      // Time-series: sin(t * 0.02 * PI) * 0.4 + 0.5 + noise
      ts[i] = clamp01(Math.sin(t * 0.02 * Math.PI) * 0.4 + 0.5 + gaussianNoise(0.05));
      t++;

      // Scatter 2D: random walk center + gaussian cluster
      centerX += gaussianNoise(0.01);
      centerY += gaussianNoise(0.01);
      centerX = clamp01(centerX);
      centerY = clamp01(centerY);
      sc[i * 2] = clamp01(centerX + gaussianNoise(0.15));
      sc[i * 2 + 1] = clamp01(centerY + gaussianNoise(0.15));

      // Values 1D: 0.5 + noise
      v1[i] = clamp01(0.5 + gaussianNoise(0.15));
    }

    targets.timeSeries.push(ts);
    targets.scatter2D.push(sc);
    targets.values1D.push(v1);
    onData();
  }

  return {
    start() {
      if (timer !== null) return;
      timer = setInterval(tick, config.interval);
    },
    stop() {
      if (timer !== null) {
        clearInterval(timer);
        timer = null;
      }
    },
  };
}
