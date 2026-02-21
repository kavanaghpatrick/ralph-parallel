# Tasks: API Dashboard

## Phase 1: Core Dashboard

- [x] 1.1 [P] Create dashboard layout component
  - **Files**: `src/components/DashboardLayout.tsx`, `src/styles/dashboard.css`
  - **Do**:
    1. Build responsive layout with sidebar and main content area
    2. Add navigation menu items
    3. Style with CSS modules
  - **Done when**: Layout renders with sidebar and content area
  - **Verify**: `npm test -- --grep "DashboardLayout"`
  - **Commit**: `feat: add dashboard layout component`

- [x] 1.2 [P] Build API metrics endpoint
  - **Files**: `src/api/metrics.ts`, `src/api/metrics.test.ts`
  - **Do**:
    1. GET /api/metrics - return request counts, latency, error rates
    2. Aggregate from logs table by time window
    3. Support ?window=1h|6h|24h|7d query param
  - **Done when**: Endpoint returns aggregated metrics
  - **Verify**: `npm test -- --grep "metrics"`
  - **Commit**: `feat: add API metrics endpoint`

- [x] 1.3 [P] Create metrics chart component
  - **Files**: `src/components/MetricsChart.tsx`, `src/components/MetricsChart.test.tsx`
  - **Do**:
    1. Line chart showing requests/min over time
    2. Bar chart showing error rates by endpoint
    3. Use recharts library
    4. Auto-refresh every 30 seconds
  - **Done when**: Charts render with mock data and auto-refresh
  - **Verify**: `npm test -- --grep "MetricsChart"`
  - **Commit**: `feat: add metrics chart components`

- [x] 1.4 [P] Build API key management
  - **Files**: `src/api/keys.ts`, `src/api/keys.test.ts`, `src/models/ApiKey.ts`
  - **Do**:
    1. CRUD endpoints for API keys
    2. Generate secure random keys
    3. Support key rotation (create new, deprecate old)
    4. Rate limit per key
  - **Done when**: Can create, list, rotate, and delete API keys
  - **Verify**: `npm test -- --grep "API keys"`
  - **Commit**: `feat: add API key management endpoints`

- [x] 1.5 [P] Create API key management UI
  - **Files**: `src/components/ApiKeyManager.tsx`, `src/components/ApiKeyManager.test.tsx`
  - **Do**:
    1. Table listing all API keys with status
    2. Create key dialog with name and permissions
    3. Rotate/delete actions with confirmation
    4. Copy key to clipboard
  - **Done when**: UI manages full API key lifecycle
  - **Verify**: `npm test -- --grep "ApiKeyManager"`
  - **Commit**: `feat: add API key management UI`

- [ ] 1.6 [VERIFY] Phase 1 integration verification
  - **Files**: none
  - **Do**:
    1. Run full test suite
    2. Verify dashboard loads with metrics and key management
  - **Done when**: All tests pass
  - **Verify**: `npm test && npm run typecheck`
  - **Commit**: none
