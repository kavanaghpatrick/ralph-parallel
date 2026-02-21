import { describe, it, expect, beforeEach } from "vitest";
import {
  handleRegister,
  handleLogin,
  clearUsers,
  registerSchema,
  loginSchema,
  findUserByEmail,
} from "./auth.js";

describe("auth routes", () => {
  beforeEach(() => {
    clearUsers();
  });

  describe("registerSchema", () => {
    it("rejects invalid email", () => {
      const result = registerSchema.safeParse({ email: "bad", password: "12345678" });
      expect(result.success).toBe(false);
    });

    it("rejects short password", () => {
      const result = registerSchema.safeParse({ email: "a@b.com", password: "short" });
      expect(result.success).toBe(false);
    });

    it("accepts valid input", () => {
      const result = registerSchema.safeParse({ email: "a@b.com", password: "12345678" });
      expect(result.success).toBe(true);
    });
  });

  describe("loginSchema", () => {
    it("rejects invalid email", () => {
      const result = loginSchema.safeParse({ email: "bad", password: "anything" });
      expect(result.success).toBe(false);
    });

    it("rejects empty password", () => {
      const result = loginSchema.safeParse({ email: "a@b.com", password: "" });
      expect(result.success).toBe(false);
    });

    it("accepts valid input", () => {
      const result = loginSchema.safeParse({ email: "a@b.com", password: "anything" });
      expect(result.success).toBe(true);
    });
  });

  describe("handleRegister", () => {
    it("creates user and returns token on valid input", async () => {
      const result = await handleRegister({
        email: "test@example.com",
        password: "securepassword",
      });

      expect(result.status).toBe(201);
      expect(result.body).toHaveProperty("token");
      expect(result.body).toHaveProperty("user");
      if ("user" in result.body) {
        expect(result.body.user.email).toBe("test@example.com");
        expect(result.body.user.id).toBeDefined();
      }
    });

    it("returns 400 for invalid input", async () => {
      const result = await handleRegister({ email: "bad", password: "x" });

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Validation failed");
        expect(result.body.details).toBeDefined();
      }
    });

    it("returns 409 for duplicate email", async () => {
      await handleRegister({ email: "dup@example.com", password: "password123" });
      const result = await handleRegister({ email: "dup@example.com", password: "password456" });

      expect(result.status).toBe(409);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Email already registered");
      }
    });

    it("stores user with hashed password", async () => {
      await handleRegister({ email: "hash@example.com", password: "plaintext" });
      const user = findUserByEmail("hash@example.com");

      expect(user).toBeDefined();
      expect(user!.passwordHash).not.toBe("plaintext");
      expect(user!.passwordHash.startsWith("$2")).toBe(true);
    });
  });

  describe("handleLogin", () => {
    beforeEach(async () => {
      await handleRegister({ email: "user@example.com", password: "correctpassword" });
    });

    it("returns token on valid credentials", async () => {
      const result = await handleLogin({
        email: "user@example.com",
        password: "correctpassword",
      });

      expect(result.status).toBe(200);
      expect(result.body).toHaveProperty("token");
      if ("user" in result.body) {
        expect(result.body.user.email).toBe("user@example.com");
      }
    });

    it("returns 401 for wrong password", async () => {
      const result = await handleLogin({
        email: "user@example.com",
        password: "wrongpassword",
      });

      expect(result.status).toBe(401);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Invalid email or password");
      }
    });

    it("returns 401 for non-existent email", async () => {
      const result = await handleLogin({
        email: "nobody@example.com",
        password: "anything",
      });

      expect(result.status).toBe(401);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Invalid email or password");
      }
    });

    it("returns 400 for invalid input", async () => {
      const result = await handleLogin({ email: "bad" });

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Validation failed");
      }
    });
  });
});
