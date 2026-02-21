import crypto from "node:crypto";

export interface ApiKey {
  id: string;
  name: string;
  key: string;
  keyPrefix: string;
  status: "active" | "deprecated" | "revoked";
  rateLimit: number;
  requestCount: number;
  lastUsedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

export interface CreateApiKeyInput {
  name: string;
  rateLimit?: number;
}

const DEFAULT_RATE_LIMIT = 1000; // requests per hour

// In-memory store (replace with database in production)
const apiKeys = new Map<string, ApiKey>();

export function generateSecureKey(): string {
  return crypto.randomBytes(32).toString("hex");
}

export function createApiKey(input: CreateApiKeyInput): ApiKey {
  const key = generateSecureKey();
  const apiKey: ApiKey = {
    id: crypto.randomUUID(),
    name: input.name,
    key,
    keyPrefix: key.slice(0, 8),
    status: "active",
    rateLimit: input.rateLimit ?? DEFAULT_RATE_LIMIT,
    requestCount: 0,
    lastUsedAt: null,
    createdAt: new Date(),
    updatedAt: new Date(),
  };
  apiKeys.set(apiKey.id, apiKey);
  return apiKey;
}

export function findApiKeyById(id: string): ApiKey | undefined {
  return apiKeys.get(id);
}

export function findApiKeyByKey(key: string): ApiKey | undefined {
  for (const apiKey of apiKeys.values()) {
    if (apiKey.key === key && apiKey.status === "active") {
      return apiKey;
    }
  }
  return undefined;
}

export function listApiKeys(): ApiKey[] {
  return Array.from(apiKeys.values());
}

export function rotateApiKey(id: string): { oldKey: ApiKey; newKey: ApiKey } | undefined {
  const existing = apiKeys.get(id);
  if (!existing || existing.status !== "active") {
    return undefined;
  }

  // Deprecate the old key
  existing.status = "deprecated";
  existing.updatedAt = new Date();

  // Create a new key with the same name and rate limit
  const newKey = createApiKey({
    name: existing.name,
    rateLimit: existing.rateLimit,
  });

  return { oldKey: existing, newKey };
}

export function deleteApiKey(id: string): boolean {
  const existing = apiKeys.get(id);
  if (!existing) {
    return false;
  }
  existing.status = "revoked";
  existing.updatedAt = new Date();
  return true;
}

export function checkRateLimit(apiKey: ApiKey): boolean {
  return apiKey.requestCount < apiKey.rateLimit;
}

export function incrementRequestCount(id: string): ApiKey | undefined {
  const apiKey = apiKeys.get(id);
  if (!apiKey) return undefined;
  apiKey.requestCount++;
  apiKey.lastUsedAt = new Date();
  return apiKey;
}

export function resetRequestCount(id: string): ApiKey | undefined {
  const apiKey = apiKeys.get(id);
  if (!apiKey) return undefined;
  apiKey.requestCount = 0;
  return apiKey;
}

// For testing
export function clearApiKeys(): void {
  apiKeys.clear();
}
