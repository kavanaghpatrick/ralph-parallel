/**
 * Request adapter + device. Returns null if WebGPU unsupported or init fails.
 * Logs failure reason to console.
 */
export async function initGPU(): Promise<GPUDevice | null> {
  try {
    if (!navigator.gpu) {
      console.error('WebGPU: navigator.gpu is not available');
      return null;
    }

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      console.error('WebGPU: requestAdapter() returned null');
      return null;
    }

    const device = await adapter.requestDevice();
    if (!device) {
      console.error('WebGPU: requestDevice() returned null');
      return null;
    }

    return device;
  } catch (err) {
    console.error('WebGPU: initialization failed:', err);
    return null;
  }
}

/**
 * Replace container contents with a styled fallback message.
 * Called when initGPU() returns null.
 */
export function showFallback(container: HTMLElement, reason: string): void {
  container.classList.add('visible');
  container.innerHTML = `
    <div>
      <p style="font-size: 24px; margin-bottom: 16px;">WebGPU is not supported in this browser</p>
      <p style="color: #a0a0c0;">${reason}</p>
      <p style="color: #666; margin-top: 24px;">Try Chrome 113+ or Edge 113+ with WebGPU enabled.</p>
    </div>
  `;
}
