import React from 'react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import { MetricsChart, MetricsData } from './MetricsChart.js';

// recharts uses ResizeObserver internally
class ResizeObserverMock {
  observe() {}
  unobserve() {}
  disconnect() {}
}
(globalThis as any).ResizeObserver = ResizeObserverMock;

const mockMetricsData: MetricsData = {
  requestsOverTime: [
    { time: '10:00', requestsPerMin: 120 },
    { time: '10:05', requestsPerMin: 135 },
    { time: '10:10', requestsPerMin: 98 },
    { time: '10:15', requestsPerMin: 142 },
  ],
  errorsByEndpoint: [
    { endpoint: '/api/users', errorRate: 2.1 },
    { endpoint: '/api/orders', errorRate: 5.4 },
    { endpoint: '/api/products', errorRate: 0.8 },
  ],
};

describe('MetricsChart', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('shows loading state initially', () => {
    const fetchMetrics = vi.fn().mockReturnValue(new Promise(() => {}));
    render(<MetricsChart fetchMetrics={fetchMetrics} />);
    expect(screen.getByText('Loading metrics...')).toBeDefined();
  });

  it('renders charts with data after fetch', async () => {
    const fetchMetrics = vi.fn().mockResolvedValue(mockMetricsData);
    render(<MetricsChart fetchMetrics={fetchMetrics} />);

    await waitFor(() => {
      expect(screen.getByText('Requests per Minute')).toBeDefined();
      expect(screen.getByText('Error Rates by Endpoint')).toBeDefined();
    });

    expect(fetchMetrics).toHaveBeenCalledWith('1h');
  });

  it('displays error message on fetch failure', async () => {
    const fetchMetrics = vi.fn().mockRejectedValue(new Error('API error'));
    render(<MetricsChart fetchMetrics={fetchMetrics} />);

    await waitFor(() => {
      expect(screen.getByText('Failed to load metrics')).toBeDefined();
    });
  });

  it('passes window parameter to fetch function', async () => {
    const fetchMetrics = vi.fn().mockResolvedValue(mockMetricsData);
    render(<MetricsChart fetchMetrics={fetchMetrics} window="24h" />);

    await waitFor(() => {
      expect(fetchMetrics).toHaveBeenCalledWith('24h');
    });
  });

  it('auto-refreshes at the specified interval', async () => {
    vi.useFakeTimers();
    let callCount = 0;
    const fetchMetrics = vi.fn().mockImplementation(() => {
      callCount++;
      return Promise.resolve(mockMetricsData);
    });

    render(<MetricsChart fetchMetrics={fetchMetrics} refreshInterval={30000} />);

    // Initial call
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });

    expect(fetchMetrics).toHaveBeenCalledTimes(1);

    // After 30 seconds
    await act(async () => {
      await vi.advanceTimersByTimeAsync(30000);
    });

    expect(fetchMetrics).toHaveBeenCalledTimes(2);

    // After another 30 seconds
    await act(async () => {
      await vi.advanceTimersByTimeAsync(30000);
    });

    expect(fetchMetrics).toHaveBeenCalledTimes(3);

    vi.useRealTimers();
  });

  it('cleans up interval on unmount', async () => {
    vi.useFakeTimers();
    const fetchMetrics = vi.fn().mockImplementation(() => Promise.resolve(mockMetricsData));

    const { unmount } = render(
      <MetricsChart fetchMetrics={fetchMetrics} refreshInterval={30000} />
    );

    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });

    expect(fetchMetrics).toHaveBeenCalledTimes(1);

    unmount();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30000);
    });

    expect(fetchMetrics).toHaveBeenCalledTimes(1);

    vi.useRealTimers();
  });

  it('renders line chart section and bar chart section', async () => {
    const fetchMetrics = vi.fn().mockResolvedValue(mockMetricsData);
    render(<MetricsChart fetchMetrics={fetchMetrics} />);

    await waitFor(() => {
      expect(screen.getByLabelText('Requests per minute')).toBeDefined();
      expect(screen.getByLabelText('Error rates by endpoint')).toBeDefined();
    });
  });

  it('uses default 1h window when not specified', async () => {
    const fetchMetrics = vi.fn().mockResolvedValue(mockMetricsData);
    render(<MetricsChart fetchMetrics={fetchMetrics} />);

    await waitFor(() => {
      expect(fetchMetrics).toHaveBeenCalledWith('1h');
    });
  });
});
