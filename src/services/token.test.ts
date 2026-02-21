import { describe, it, expect } from "vitest";
import jwt from "jsonwebtoken";
import { generateToken, verifyToken, DecodedToken } from "./token.js";

describe("token service", () => {
  const userId = "user-123";
  const email = "test@example.com";

  describe("generateToken", () => {
    it("should return a valid JWT string", () => {
      const token = generateToken(userId, email);
      expect(token).toBeTypeOf("string");
      expect(token.split(".")).toHaveLength(3);
    });

    it("should encode userId and email in the payload", () => {
      const token = generateToken(userId, email);
      const decoded = jwt.decode(token) as DecodedToken;
      expect(decoded.userId).toBe(userId);
      expect(decoded.email).toBe(email);
    });

    it("should include exp and iat claims", () => {
      const token = generateToken(userId, email);
      const decoded = jwt.decode(token) as DecodedToken;
      expect(decoded.iat).toBeTypeOf("number");
      expect(decoded.exp).toBeTypeOf("number");
      expect(decoded.exp).toBeGreaterThan(decoded.iat);
    });

    it("should set expiry to 24 hours", () => {
      const token = generateToken(userId, email);
      const decoded = jwt.decode(token) as DecodedToken;
      const twentyFourHours = 24 * 60 * 60;
      expect(decoded.exp - decoded.iat).toBe(twentyFourHours);
    });
  });

  describe("verifyToken", () => {
    it("should verify and return the decoded payload", () => {
      const token = generateToken(userId, email);
      const decoded = verifyToken(token);
      expect(decoded.userId).toBe(userId);
      expect(decoded.email).toBe(email);
    });

    it("should throw for an invalid token", () => {
      expect(() => verifyToken("invalid.token.here")).toThrow();
    });

    it("should throw for a token signed with a different secret", () => {
      const token = jwt.sign({ userId, email }, "wrong-secret", {
        expiresIn: "24h",
      });
      expect(() => verifyToken(token)).toThrow();
    });

    it("should throw for an expired token", () => {
      const secret = process.env.JWT_SECRET || "dev-secret-change-in-production";
      const token = jwt.sign({ userId, email }, secret, {
        expiresIn: "-1s",
      });
      expect(() => verifyToken(token)).toThrow(jwt.TokenExpiredError);
    });
  });

  describe("round-trip", () => {
    it("should generate and verify tokens correctly", () => {
      const token = generateToken(userId, email);
      const decoded = verifyToken(token);
      expect(decoded.userId).toBe(userId);
      expect(decoded.email).toBe(email);
      expect(decoded.exp).toBeTypeOf("number");
      expect(decoded.iat).toBeTypeOf("number");
    });
  });
});
