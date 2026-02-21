import React, { useState, useEffect, useCallback } from 'react';
import {
  LineChart,
  Line,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';

export interface RequestsOverTimePoint {
  time: string;
  requestsPerMin: number;
}

export interface ErrorRateByEndpoint {
  endpoint: string;
  errorRate: number;
}

export interface MetricsData {
  requestsOverTime: RequestsOverTimePoint[];
  errorsByEndpoint: ErrorRateByEndpoint[];
}

interface MetricsChartProps {
  window?: '1h' | '6h' | '24h' | '7d';
  refreshInterval?: number;
  fetchMetrics?: (window: string) => Promise<MetricsData>;
}

const DEFAULT_REFRESH_INTERVAL = 30000;

async function defaultFetchMetrics(window: string): Promise<MetricsData> {
  const response = await fetch(`/api/metrics?window=${window}`);
  if (!response.ok) {
    throw new Error('Failed to fetch metrics');
  }
  return response.json();
}

export function MetricsChart({
  window = '1h',
  refreshInterval = DEFAULT_REFRESH_INTERVAL,
  fetchMetrics = defaultFetchMetrics,
}: MetricsChartProps) {
  const [data, setData] = useState<MetricsData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const loadMetrics = useCallback(async () => {
    try {
      const metrics = await fetchMetrics(window);
      setData(metrics);
      setError(null);
    } catch {
      setError('Failed to load metrics');
    } finally {
      setLoading(false);
    }
  }, [fetchMetrics, window]);

  useEffect(() => {
    loadMetrics();
    const interval = setInterval(loadMetrics, refreshInterval);
    return () => clearInterval(interval);
  }, [loadMetrics, refreshInterval]);

  if (loading && !data) {
    return <div role="status">Loading metrics...</div>;
  }

  if (error && !data) {
    return <div role="alert">{error}</div>;
  }

  return (
    <div aria-label="Metrics charts">
      <section aria-label="Requests per minute">
        <h3>Requests per Minute</h3>
        <ResponsiveContainer width="100%" height={300}>
          <LineChart data={data?.requestsOverTime ?? []}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis dataKey="time" />
            <YAxis />
            <Tooltip />
            <Legend />
            <Line
              type="monotone"
              dataKey="requestsPerMin"
              stroke="#8884d8"
              name="Requests/min"
            />
          </LineChart>
        </ResponsiveContainer>
      </section>

      <section aria-label="Error rates by endpoint">
        <h3>Error Rates by Endpoint</h3>
        <ResponsiveContainer width="100%" height={300}>
          <BarChart data={data?.errorsByEndpoint ?? []}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis dataKey="endpoint" />
            <YAxis />
            <Tooltip />
            <Legend />
            <Bar dataKey="errorRate" fill="#ff6b6b" name="Error Rate %" />
          </BarChart>
        </ResponsiveContainer>
      </section>
    </div>
  );
}
