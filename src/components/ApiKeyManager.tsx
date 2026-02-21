import React, { useState, useEffect, useCallback } from 'react';

export interface ApiKeyItem {
  id: string;
  name: string;
  keyPrefix: string;
  status: 'active' | 'deprecated' | 'revoked';
  rateLimit: number;
  requestCount: number;
  lastUsedAt: string | null;
  createdAt: string;
}

export interface CreateKeyResponse {
  id: string;
  name: string;
  key: string;
  keyPrefix: string;
  status: string;
  rateLimit: number;
  createdAt: string;
}

export interface ApiKeyManagerApi {
  listKeys: () => Promise<ApiKeyItem[]>;
  createKey: (name: string, rateLimit?: number) => Promise<CreateKeyResponse>;
  rotateKey: (id: string) => Promise<{ oldKeyId: string; newKey: CreateKeyResponse }>;
  deleteKey: (id: string) => Promise<{ message: string }>;
}

interface ApiKeyManagerProps {
  api?: ApiKeyManagerApi;
}

const defaultApi: ApiKeyManagerApi = {
  async listKeys() {
    const res = await fetch('/api/keys');
    if (!res.ok) throw new Error('Failed to fetch keys');
    return res.json();
  },
  async createKey(name: string, rateLimit?: number) {
    const res = await fetch('/api/keys', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, rateLimit }),
    });
    if (!res.ok) throw new Error('Failed to create key');
    return res.json();
  },
  async rotateKey(id: string) {
    const res = await fetch(`/api/keys/${id}/rotate`, { method: 'POST' });
    if (!res.ok) throw new Error('Failed to rotate key');
    return res.json();
  },
  async deleteKey(id: string) {
    const res = await fetch(`/api/keys/${id}`, { method: 'DELETE' });
    if (!res.ok) throw new Error('Failed to delete key');
    return res.json();
  },
};

export function ApiKeyManager({ api = defaultApi }: ApiKeyManagerProps) {
  const [keys, setKeys] = useState<ApiKeyItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showCreateDialog, setShowCreateDialog] = useState(false);
  const [newKeyName, setNewKeyName] = useState('');
  const [newKeyRateLimit, setNewKeyRateLimit] = useState('');
  const [createdKey, setCreatedKey] = useState<string | null>(null);
  const [copySuccess, setCopySuccess] = useState(false);

  const [confirmAction, setConfirmAction] = useState<{
    type: 'rotate' | 'delete';
    keyId: string;
    keyName: string;
  } | null>(null);

  const loadKeys = useCallback(async () => {
    try {
      const data = await api.listKeys();
      setKeys(data);
      setError(null);
    } catch {
      setError('Failed to load API keys');
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    loadKeys();
  }, [loadKeys]);

  async function handleCreateKey() {
    if (!newKeyName.trim()) return;
    try {
      const rateLimit = newKeyRateLimit ? parseInt(newKeyRateLimit, 10) : undefined;
      const result = await api.createKey(newKeyName.trim(), rateLimit);
      setCreatedKey(result.key);
      setNewKeyName('');
      setNewKeyRateLimit('');
      await loadKeys();
    } catch {
      setError('Failed to create API key');
    }
  }

  async function handleRotateKey(id: string) {
    try {
      const result = await api.rotateKey(id);
      setCreatedKey(result.newKey.key);
      setConfirmAction(null);
      await loadKeys();
    } catch {
      setError('Failed to rotate API key');
    }
  }

  async function handleDeleteKey(id: string) {
    try {
      await api.deleteKey(id);
      setConfirmAction(null);
      await loadKeys();
    } catch {
      setError('Failed to delete API key');
    }
  }

  async function handleCopyKey() {
    if (!createdKey) return;
    try {
      await navigator.clipboard.writeText(createdKey);
      setCopySuccess(true);
      setTimeout(() => setCopySuccess(false), 2000);
    } catch {
      setError('Failed to copy to clipboard');
    }
  }

  function closeCreateDialog() {
    setShowCreateDialog(false);
    setNewKeyName('');
    setNewKeyRateLimit('');
    setCreatedKey(null);
    setCopySuccess(false);
  }

  if (loading) {
    return <div role="status">Loading API keys...</div>;
  }

  return (
    <div aria-label="API Key Manager">
      <h2>API Keys</h2>

      {error && (
        <div role="alert" className="error-message">
          {error}
        </div>
      )}

      <button onClick={() => setShowCreateDialog(true)}>Create New Key</button>

      {showCreateDialog && (
        <div role="dialog" aria-label="Create API key">
          <h3>Create New API Key</h3>

          {createdKey ? (
            <div>
              <p>Your new API key:</p>
              <code data-testid="created-key">{createdKey}</code>
              <button onClick={handleCopyKey}>
                {copySuccess ? 'Copied!' : 'Copy to Clipboard'}
              </button>
              <p>Save this key now. You will not be able to see it again.</p>
              <button onClick={closeCreateDialog}>Done</button>
            </div>
          ) : (
            <div>
              <div>
                <label htmlFor="key-name">Key Name</label>
                <input
                  id="key-name"
                  type="text"
                  value={newKeyName}
                  onChange={(e) => setNewKeyName(e.target.value)}
                  placeholder="My API Key"
                />
              </div>
              <div>
                <label htmlFor="key-rate-limit">Rate Limit (requests/hour)</label>
                <input
                  id="key-rate-limit"
                  type="number"
                  value={newKeyRateLimit}
                  onChange={(e) => setNewKeyRateLimit(e.target.value)}
                  placeholder="1000"
                />
              </div>
              <button onClick={handleCreateKey}>Create Key</button>
              <button onClick={closeCreateDialog}>Cancel</button>
            </div>
          )}
        </div>
      )}

      {confirmAction && (
        <div role="dialog" aria-label="Confirm action">
          <p>
            Are you sure you want to {confirmAction.type} the key "{confirmAction.keyName}"?
          </p>
          <button
            onClick={() =>
              confirmAction.type === 'rotate'
                ? handleRotateKey(confirmAction.keyId)
                : handleDeleteKey(confirmAction.keyId)
            }
          >
            Confirm
          </button>
          <button onClick={() => setConfirmAction(null)}>Cancel</button>
        </div>
      )}

      <table aria-label="API keys list">
        <thead>
          <tr>
            <th>Name</th>
            <th>Key Prefix</th>
            <th>Status</th>
            <th>Rate Limit</th>
            <th>Requests</th>
            <th>Created</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {keys.length === 0 ? (
            <tr>
              <td colSpan={7}>No API keys found</td>
            </tr>
          ) : (
            keys.map((key) => (
              <tr key={key.id}>
                <td>{key.name}</td>
                <td>
                  <code>{key.keyPrefix}...</code>
                </td>
                <td>{key.status}</td>
                <td>{key.rateLimit}</td>
                <td>{key.requestCount}</td>
                <td>{new Date(key.createdAt).toLocaleDateString()}</td>
                <td>
                  {key.status === 'active' && (
                    <>
                      <button
                        onClick={() =>
                          setConfirmAction({
                            type: 'rotate',
                            keyId: key.id,
                            keyName: key.name,
                          })
                        }
                      >
                        Rotate
                      </button>
                      <button
                        onClick={() =>
                          setConfirmAction({
                            type: 'delete',
                            keyId: key.id,
                            keyName: key.name,
                          })
                        }
                      >
                        Delete
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
