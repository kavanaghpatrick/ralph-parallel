import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ApiKeyManager, ApiKeyManagerApi, ApiKeyItem, CreateKeyResponse } from './ApiKeyManager.js';

const mockKeys: ApiKeyItem[] = [
  {
    id: 'key-1',
    name: 'Production Key',
    keyPrefix: 'abc12345',
    status: 'active',
    rateLimit: 1000,
    requestCount: 150,
    lastUsedAt: '2024-01-15T10:00:00.000Z',
    createdAt: '2024-01-01T00:00:00.000Z',
  },
  {
    id: 'key-2',
    name: 'Deprecated Key',
    keyPrefix: 'def67890',
    status: 'deprecated',
    rateLimit: 500,
    requestCount: 42,
    lastUsedAt: '2024-01-10T08:00:00.000Z',
    createdAt: '2023-12-01T00:00:00.000Z',
  },
];

const mockCreatedKey: CreateKeyResponse = {
  id: 'key-3',
  name: 'New Key',
  key: 'full-secret-key-value-abc123def456',
  keyPrefix: 'full1234',
  status: 'active',
  rateLimit: 1000,
  createdAt: '2024-01-20T00:00:00.000Z',
};

function createMockApi(overrides: Partial<ApiKeyManagerApi> = {}): ApiKeyManagerApi {
  return {
    listKeys: vi.fn().mockResolvedValue(mockKeys),
    createKey: vi.fn().mockResolvedValue(mockCreatedKey),
    rotateKey: vi.fn().mockResolvedValue({
      oldKeyId: 'key-1',
      newKey: mockCreatedKey,
    }),
    deleteKey: vi.fn().mockResolvedValue({ message: 'API key revoked successfully' }),
    ...overrides,
  };
}

describe('ApiKeyManager', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('shows loading state initially', () => {
    const api = createMockApi({
      listKeys: vi.fn().mockReturnValue(new Promise(() => {})),
    });
    render(<ApiKeyManager api={api} />);
    expect(screen.getByText('Loading API keys...')).toBeDefined();
  });

  it('renders table with API keys', async () => {
    const api = createMockApi();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
      expect(screen.getByText('Deprecated Key')).toBeDefined();
    });

    expect(screen.getByText('abc12345...')).toBeDefined();
    expect(screen.getByText('active')).toBeDefined();
    expect(screen.getByText('deprecated')).toBeDefined();
  });

  it('shows empty state when no keys exist', async () => {
    const api = createMockApi({
      listKeys: vi.fn().mockResolvedValue([]),
    });
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('No API keys found')).toBeDefined();
    });
  });

  it('shows error message on fetch failure', async () => {
    const api = createMockApi({
      listKeys: vi.fn().mockRejectedValue(new Error('Network error')),
    });
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Failed to load API keys')).toBeDefined();
    });
  });

  it('opens create key dialog', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    await user.click(screen.getByText('Create New Key'));

    expect(screen.getByLabelText('Key Name')).toBeDefined();
    expect(screen.getByLabelText('Rate Limit (requests/hour)')).toBeDefined();
  });

  it('creates a new key and shows the full key', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    await user.click(screen.getByText('Create New Key'));
    await user.type(screen.getByLabelText('Key Name'), 'New Key');
    await user.click(screen.getByText('Create Key'));

    await waitFor(() => {
      expect(screen.getByTestId('created-key')).toBeDefined();
      expect(screen.getByTestId('created-key').textContent).toBe(
        'full-secret-key-value-abc123def456'
      );
    });

    expect(api.createKey).toHaveBeenCalledWith('New Key', undefined);
  });

  it('creates key with custom rate limit', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    await user.click(screen.getByText('Create New Key'));
    await user.type(screen.getByLabelText('Key Name'), 'Rate Limited Key');
    await user.type(screen.getByLabelText('Rate Limit (requests/hour)'), '500');
    await user.click(screen.getByText('Create Key'));

    await waitFor(() => {
      expect(api.createKey).toHaveBeenCalledWith('Rate Limited Key', 500);
    });
  });

  it('copies key to clipboard', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    await user.click(screen.getByText('Create New Key'));
    await user.type(screen.getByLabelText('Key Name'), 'New Key');
    await user.click(screen.getByText('Create Key'));

    await waitFor(() => {
      expect(screen.getByText('Copy to Clipboard')).toBeDefined();
    });

    // Spy on navigator.clipboard.writeText after userEvent has set it up
    const writeTextSpy = vi.spyOn(navigator.clipboard, 'writeText');

    await user.click(screen.getByText('Copy to Clipboard'));

    await waitFor(() => {
      expect(writeTextSpy).toHaveBeenCalledWith('full-secret-key-value-abc123def456');
      expect(screen.getByText('Copied!')).toBeDefined();
    });
  });

  it('shows rotate confirmation dialog', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    const rotateButtons = screen.getAllByText('Rotate');
    await user.click(rotateButtons[0]);

    expect(
      screen.getByText('Are you sure you want to rotate the key "Production Key"?')
    ).toBeDefined();
  });

  it('rotates key after confirmation', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    const rotateButtons = screen.getAllByText('Rotate');
    await user.click(rotateButtons[0]);
    await user.click(screen.getByText('Confirm'));

    await waitFor(() => {
      expect(api.rotateKey).toHaveBeenCalledWith('key-1');
    });
  });

  it('shows delete confirmation dialog', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    const deleteButtons = screen.getAllByText('Delete');
    await user.click(deleteButtons[0]);

    expect(
      screen.getByText('Are you sure you want to delete the key "Production Key"?')
    ).toBeDefined();
  });

  it('deletes key after confirmation', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    const deleteButtons = screen.getAllByText('Delete');
    await user.click(deleteButtons[0]);
    await user.click(screen.getByText('Confirm'));

    await waitFor(() => {
      expect(api.deleteKey).toHaveBeenCalledWith('key-1');
    });
  });

  it('cancels confirmation dialog', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    const deleteButtons = screen.getAllByText('Delete');
    await user.click(deleteButtons[0]);

    expect(screen.getByLabelText('Confirm action')).toBeDefined();

    await user.click(screen.getByText('Cancel'));

    expect(screen.queryByLabelText('Confirm action')).toBeNull();
  });

  it('does not show rotate/delete for non-active keys', async () => {
    const api = createMockApi({
      listKeys: vi.fn().mockResolvedValue([mockKeys[1]]), // Only deprecated key
    });
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Deprecated Key')).toBeDefined();
    });

    expect(screen.queryByText('Rotate')).toBeNull();
    expect(screen.queryByText('Delete')).toBeNull();
  });

  it('closes create dialog on cancel', async () => {
    const api = createMockApi();
    const user = userEvent.setup();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Production Key')).toBeDefined();
    });

    await user.click(screen.getByText('Create New Key'));
    expect(screen.getByLabelText('Create API key')).toBeDefined();

    await user.click(screen.getByText('Cancel'));
    expect(screen.queryByLabelText('Create API key')).toBeNull();
  });

  it('renders the table header columns', async () => {
    const api = createMockApi();
    render(<ApiKeyManager api={api} />);

    await waitFor(() => {
      expect(screen.getByText('Name')).toBeDefined();
      expect(screen.getByText('Key Prefix')).toBeDefined();
      expect(screen.getByText('Status')).toBeDefined();
      expect(screen.getByText('Rate Limit')).toBeDefined();
      expect(screen.getByText('Requests')).toBeDefined();
      expect(screen.getByText('Created')).toBeDefined();
      expect(screen.getByText('Actions')).toBeDefined();
    });
  });
});
