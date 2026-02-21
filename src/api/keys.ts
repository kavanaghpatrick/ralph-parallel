import { z } from "zod";
import {
  createApiKey,
  findApiKeyById,
  findApiKeyByKey,
  listApiKeys,
  rotateApiKey,
  deleteApiKey,
  checkRateLimit,
  incrementRequestCount,
  type ApiKey,
} from "../models/ApiKey.js";

// --- Zod Schemas ---

export const createKeySchema = z.object({
  name: z.string().min(1, "Key name is required").max(100, "Key name too long"),
  rateLimit: z.number().int().positive().optional(),
});

export type CreateKeyInput = z.infer<typeof createKeySchema>;

// --- Response types ---

export interface KeyResponse {
  id: string;
  name: string;
  key: string;
  keyPrefix: string;
  status: ApiKey["status"];
  rateLimit: number;
  createdAt: string;
}

export interface KeyListItem {
  id: string;
  name: string;
  keyPrefix: string;
  status: ApiKey["status"];
  rateLimit: number;
  requestCount: number;
  lastUsedAt: string | null;
  createdAt: string;
}

export interface ErrorResponse {
  error: string;
  details?: Array<{ path: string; message: string }>;
}

export interface RotateResponse {
  oldKeyId: string;
  newKey: KeyResponse;
}

export interface MessageResponse {
  message: string;
}

// --- Helpers ---

function toKeyResponse(apiKey: ApiKey): KeyResponse {
  return {
    id: apiKey.id,
    name: apiKey.name,
    key: apiKey.key,
    keyPrefix: apiKey.keyPrefix,
    status: apiKey.status,
    rateLimit: apiKey.rateLimit,
    createdAt: apiKey.createdAt.toISOString(),
  };
}

function toKeyListItem(apiKey: ApiKey): KeyListItem {
  return {
    id: apiKey.id,
    name: apiKey.name,
    keyPrefix: apiKey.keyPrefix,
    status: apiKey.status,
    rateLimit: apiKey.rateLimit,
    requestCount: apiKey.requestCount,
    lastUsedAt: apiKey.lastUsedAt?.toISOString() ?? null,
    createdAt: apiKey.createdAt.toISOString(),
  };
}

// --- Route Handlers ---

export function handleCreateKey(
  body: unknown,
): { status: number; body: KeyResponse | ErrorResponse } {
  const parsed = createKeySchema.safeParse(body);
  if (!parsed.success) {
    return {
      status: 400,
      body: {
        error: "Validation failed",
        details: parsed.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
    };
  }

  const apiKey = createApiKey(parsed.data);

  return {
    status: 201,
    body: toKeyResponse(apiKey),
  };
}

export function handleListKeys(): { status: number; body: KeyListItem[] } {
  const keys = listApiKeys();
  return {
    status: 200,
    body: keys.map(toKeyListItem),
  };
}

export function handleGetKey(
  id: string,
): { status: number; body: KeyListItem | ErrorResponse } {
  const apiKey = findApiKeyById(id);
  if (!apiKey) {
    return {
      status: 404,
      body: { error: "API key not found" },
    };
  }
  return {
    status: 200,
    body: toKeyListItem(apiKey),
  };
}

export function handleRotateKey(
  id: string,
): { status: number; body: RotateResponse | ErrorResponse } {
  const result = rotateApiKey(id);
  if (!result) {
    return {
      status: 404,
      body: { error: "API key not found or not active" },
    };
  }

  return {
    status: 200,
    body: {
      oldKeyId: result.oldKey.id,
      newKey: toKeyResponse(result.newKey),
    },
  };
}

export function handleDeleteKey(
  id: string,
): { status: number; body: MessageResponse | ErrorResponse } {
  const deleted = deleteApiKey(id);
  if (!deleted) {
    return {
      status: 404,
      body: { error: "API key not found" },
    };
  }

  return {
    status: 200,
    body: { message: "API key revoked successfully" },
  };
}

export function handleValidateKey(
  key: string,
): { status: number; body: { valid: boolean; keyId?: string } | ErrorResponse } {
  const apiKey = findApiKeyByKey(key);
  if (!apiKey) {
    return {
      status: 401,
      body: { valid: false },
    };
  }

  if (!checkRateLimit(apiKey)) {
    return {
      status: 429,
      body: { error: "Rate limit exceeded" },
    };
  }

  incrementRequestCount(apiKey.id);

  return {
    status: 200,
    body: { valid: true, keyId: apiKey.id },
  };
}
