import { describe, it, expect } from "vitest";
import { requireAuth } from "./middleware.js";
import { generateToken } from "../services/token.js";

describe("middleware", () => {
  describe("requireAuth", () => {
    it("returns authenticated user for valid Bearer token", () => {
      const token = generateToken("42", "user@example.com");
      const result = requireAuth({
        headers: { authorization: `Bearer ${token}` },
      });

      expect(result.authenticated).toBe(true);
      if (result.authenticated) {
        expect(result.user.userId).toBe("42");
        expect(result.user.email).toBe("user@example.com");
      }
    });

    it("returns 401 when Authorization header is missing", () => {
      const result = requireAuth({ headers: {} });

      expect(result.authenticated).toBe(false);
      if (!result.authenticated) {
        expect(result.status).toBe(401);
        expect(result.body.error).toBe("Missing Authorization header");
      }
    });

    it("returns 401 for malformed Authorization header", () => {
      const result = requireAuth({
        headers: { authorization: "NotBearer token123" },
      });

      expect(result.authenticated).toBe(false);
      if (!result.authenticated) {
        expect(result.status).toBe(401);
        expect(result.body.error).toContain("Invalid Authorization header format");
      }
    });

    it("returns 401 for token without Bearer prefix", () => {
      const token = generateToken("1", "a@b.com");
      const result = requireAuth({
        headers: { authorization: token },
      });

      expect(result.authenticated).toBe(false);
      if (!result.authenticated) {
        expect(result.status).toBe(401);
      }
    });

    it("returns 401 for invalid token", () => {
      const result = requireAuth({
        headers: { authorization: "Bearer invalid.token.value" },
      });

      expect(result.authenticated).toBe(false);
      if (!result.authenticated) {
        expect(result.status).toBe(401);
        expect(result.body.error).toBe("Invalid or expired token");
      }
    });

    it("returns 401 for empty Bearer value", () => {
      const result = requireAuth({
        headers: { authorization: "Bearer " },
      });

      expect(result.authenticated).toBe(false);
      if (!result.authenticated) {
        expect(result.status).toBe(401);
      }
    });
  });
});
