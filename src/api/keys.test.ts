import { describe, it, expect, beforeEach } from "vitest";
import {
  handleCreateKey,
  handleListKeys,
  handleGetKey,
  handleRotateKey,
  handleDeleteKey,
  handleValidateKey,
  createKeySchema,
} from "./keys.js";
import {
  clearApiKeys,
  createApiKey,
  findApiKeyById,
  incrementRequestCount,
} from "../models/ApiKey.js";

describe("API keys", () => {
  beforeEach(() => {
    clearApiKeys();
  });

  describe("createKeySchema", () => {
    it("rejects empty name", () => {
      const result = createKeySchema.safeParse({ name: "" });
      expect(result.success).toBe(false);
    });

    it("rejects name over 100 chars", () => {
      const result = createKeySchema.safeParse({ name: "a".repeat(101) });
      expect(result.success).toBe(false);
    });

    it("accepts valid input", () => {
      const result = createKeySchema.safeParse({ name: "My API Key" });
      expect(result.success).toBe(true);
    });

    it("accepts valid input with rateLimit", () => {
      const result = createKeySchema.safeParse({ name: "My Key", rateLimit: 500 });
      expect(result.success).toBe(true);
    });

    it("rejects negative rateLimit", () => {
      const result = createKeySchema.safeParse({ name: "My Key", rateLimit: -1 });
      expect(result.success).toBe(false);
    });
  });

  describe("handleCreateKey", () => {
    it("creates a new API key and returns it", () => {
      const result = handleCreateKey({ name: "Test Key" });

      expect(result.status).toBe(201);
      if ("key" in result.body) {
        expect(result.body.name).toBe("Test Key");
        expect(result.body.key).toBeDefined();
        expect(result.body.key.length).toBe(64); // 32 bytes hex
        expect(result.body.keyPrefix).toBe(result.body.key.slice(0, 8));
        expect(result.body.status).toBe("active");
        expect(result.body.rateLimit).toBe(1000); // default
      }
    });

    it("creates key with custom rate limit", () => {
      const result = handleCreateKey({ name: "Custom Key", rateLimit: 500 });

      expect(result.status).toBe(201);
      if ("rateLimit" in result.body) {
        expect(result.body.rateLimit).toBe(500);
      }
    });

    it("returns 400 for invalid input", () => {
      const result = handleCreateKey({ name: "" });

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Validation failed");
        expect(result.body.details).toBeDefined();
      }
    });

    it("returns 400 when name is missing", () => {
      const result = handleCreateKey({});

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Validation failed");
      }
    });

    it("generates unique keys for each creation", () => {
      const result1 = handleCreateKey({ name: "Key 1" });
      const result2 = handleCreateKey({ name: "Key 2" });

      expect(result1.status).toBe(201);
      expect(result2.status).toBe(201);
      if ("key" in result1.body && "key" in result2.body) {
        expect(result1.body.key).not.toBe(result2.body.key);
        expect(result1.body.id).not.toBe(result2.body.id);
      }
    });
  });

  describe("handleListKeys", () => {
    it("returns empty list when no keys exist", () => {
      const result = handleListKeys();

      expect(result.status).toBe(200);
      expect(result.body).toEqual([]);
    });

    it("returns all keys", () => {
      handleCreateKey({ name: "Key A" });
      handleCreateKey({ name: "Key B" });

      const result = handleListKeys();

      expect(result.status).toBe(200);
      expect(result.body).toHaveLength(2);
      expect(result.body[0].name).toBe("Key A");
      expect(result.body[1].name).toBe("Key B");
    });

    it("does not expose full key in list response", () => {
      handleCreateKey({ name: "Secret Key" });

      const result = handleListKeys();
      const item = result.body[0];

      // List items should have keyPrefix but not the full key
      expect(item.keyPrefix).toBeDefined();
      expect((item as any).key).toBeUndefined();
    });
  });

  describe("handleGetKey", () => {
    it("returns a key by ID", () => {
      const created = handleCreateKey({ name: "Find Me" });
      const id = "id" in created.body ? created.body.id : "";

      const result = handleGetKey(id);

      expect(result.status).toBe(200);
      if ("name" in result.body) {
        expect(result.body.name).toBe("Find Me");
      }
    });

    it("returns 404 for unknown ID", () => {
      const result = handleGetKey("nonexistent-id");

      expect(result.status).toBe(404);
      if ("error" in result.body) {
        expect(result.body.error).toBe("API key not found");
      }
    });
  });

  describe("handleRotateKey", () => {
    it("rotates an active key", () => {
      const created = handleCreateKey({ name: "Rotate Me" });
      const oldId = "id" in created.body ? created.body.id : "";

      const result = handleRotateKey(oldId);

      expect(result.status).toBe(200);
      if ("oldKeyId" in result.body) {
        expect(result.body.oldKeyId).toBe(oldId);
        expect(result.body.newKey).toBeDefined();
        expect(result.body.newKey.name).toBe("Rotate Me");
        expect(result.body.newKey.status).toBe("active");
      }

      // Old key should be deprecated
      const oldKey = findApiKeyById(oldId);
      expect(oldKey).toBeDefined();
      expect(oldKey!.status).toBe("deprecated");
    });

    it("returns 404 for non-existent key", () => {
      const result = handleRotateKey("nonexistent-id");

      expect(result.status).toBe(404);
      if ("error" in result.body) {
        expect(result.body.error).toBe("API key not found or not active");
      }
    });

    it("cannot rotate a deprecated key", () => {
      const created = handleCreateKey({ name: "Rotate Once" });
      const oldId = "id" in created.body ? created.body.id : "";

      // Rotate once (deprecates the original)
      handleRotateKey(oldId);

      // Try to rotate the now-deprecated key
      const result = handleRotateKey(oldId);

      expect(result.status).toBe(404);
      if ("error" in result.body) {
        expect(result.body.error).toBe("API key not found or not active");
      }
    });

    it("preserves rate limit on rotation", () => {
      const created = handleCreateKey({ name: "Custom Limit", rateLimit: 250 });
      const oldId = "id" in created.body ? created.body.id : "";

      const result = handleRotateKey(oldId);

      expect(result.status).toBe(200);
      if ("newKey" in result.body) {
        expect(result.body.newKey.rateLimit).toBe(250);
      }
    });
  });

  describe("handleDeleteKey", () => {
    it("revokes an existing key", () => {
      const created = handleCreateKey({ name: "Delete Me" });
      const id = "id" in created.body ? created.body.id : "";

      const result = handleDeleteKey(id);

      expect(result.status).toBe(200);
      if ("message" in result.body) {
        expect(result.body.message).toBe("API key revoked successfully");
      }

      // Key should be revoked, not deleted from store
      const key = findApiKeyById(id);
      expect(key).toBeDefined();
      expect(key!.status).toBe("revoked");
    });

    it("returns 404 for non-existent key", () => {
      const result = handleDeleteKey("nonexistent-id");

      expect(result.status).toBe(404);
      if ("error" in result.body) {
        expect(result.body.error).toBe("API key not found");
      }
    });
  });

  describe("handleValidateKey", () => {
    it("validates an active key", () => {
      const created = handleCreateKey({ name: "Validate Me" });
      const key = "key" in created.body ? created.body.key : "";

      const result = handleValidateKey(key);

      expect(result.status).toBe(200);
      if ("valid" in result.body) {
        expect(result.body.valid).toBe(true);
        expect(result.body.keyId).toBeDefined();
      }
    });

    it("rejects an unknown key", () => {
      const result = handleValidateKey("unknown-key-value");

      expect(result.status).toBe(401);
      if ("valid" in result.body) {
        expect(result.body.valid).toBe(false);
      }
    });

    it("rejects a revoked key", () => {
      const created = handleCreateKey({ name: "Revoke Me" });
      const id = "id" in created.body ? created.body.id : "";
      const key = "key" in created.body ? created.body.key : "";

      handleDeleteKey(id);

      const result = handleValidateKey(key);

      expect(result.status).toBe(401);
    });

    it("returns 429 when rate limit exceeded", () => {
      const created = handleCreateKey({ name: "Rate Limited", rateLimit: 2 });
      const key = "key" in created.body ? created.body.key : "";
      const id = "id" in created.body ? created.body.id : "";

      // Use up the rate limit
      incrementRequestCount(id);
      incrementRequestCount(id);

      const result = handleValidateKey(key);

      expect(result.status).toBe(429);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Rate limit exceeded");
      }
    });

    it("increments request count on validation", () => {
      const created = handleCreateKey({ name: "Counter" });
      const key = "key" in created.body ? created.body.key : "";
      const id = "id" in created.body ? created.body.id : "";

      handleValidateKey(key);
      handleValidateKey(key);

      const apiKey = findApiKeyById(id);
      expect(apiKey).toBeDefined();
      expect(apiKey!.requestCount).toBe(2);
      expect(apiKey!.lastUsedAt).toBeInstanceOf(Date);
    });
  });
});
