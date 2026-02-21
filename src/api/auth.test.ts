import { describe, it, expect, beforeEach } from "vitest";
import {
  handleRegister,
  handleLogin,
  handleForgotPassword,
  handleResetPassword,
  clearUsers,
  clearResetTokens,
  getResetToken,
  registerSchema,
  loginSchema,
  findUserByEmail,
} from "./auth.js";
import { getSentEmails, clearSentEmails } from "../services/email.js";

describe("auth routes", () => {
  beforeEach(() => {
    clearUsers();
    clearResetTokens();
    clearSentEmails();
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

describe("password reset", () => {
  beforeEach(async () => {
    clearUsers();
    clearResetTokens();
    clearSentEmails();
    await handleRegister({ email: "user@example.com", password: "oldpassword" });
  });

  describe("handleForgotPassword", () => {
    it("sends reset email for registered user", async () => {
      const result = await handleForgotPassword({ email: "user@example.com" });

      expect(result.status).toBe(200);
      if ("message" in result.body) {
        expect(result.body.message).toContain("reset link has been sent");
      }
      const emails = getSentEmails();
      expect(emails).toHaveLength(1);
      expect(emails[0].to).toBe("user@example.com");
      expect(emails[0].subject).toBe("Password Reset Request");
    });

    it("returns 200 for non-existent email (prevents enumeration)", async () => {
      const result = await handleForgotPassword({ email: "nobody@example.com" });

      expect(result.status).toBe(200);
      if ("message" in result.body) {
        expect(result.body.message).toContain("reset link has been sent");
      }
      expect(getSentEmails()).toHaveLength(0);
    });

    it("returns 400 for invalid email", async () => {
      const result = await handleForgotPassword({ email: "bad" });

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Validation failed");
      }
    });

    it("generates a reset token", async () => {
      await handleForgotPassword({ email: "user@example.com" });
      const emails = getSentEmails();
      // Extract token from email body
      const match = emails[0].body.match(/token=([a-f0-9]+)/);
      expect(match).toBeTruthy();
      const token = match![1];
      const stored = getResetToken(token);
      expect(stored).toBeDefined();
      expect(stored!.expiresAt.getTime()).toBeGreaterThan(Date.now());
    });
  });

  describe("handleResetPassword", () => {
    let resetToken: string;

    beforeEach(async () => {
      await handleForgotPassword({ email: "user@example.com" });
      const emails = getSentEmails();
      const match = emails[0].body.match(/token=([a-f0-9]+)/);
      resetToken = match![1];
    });

    it("resets password with valid token", async () => {
      const result = await handleResetPassword({
        token: resetToken,
        password: "newpassword123",
      });

      expect(result.status).toBe(200);
      if ("message" in result.body) {
        expect(result.body.message).toBe("Password has been reset successfully");
      }

      // Verify new password works for login
      const loginResult = await handleLogin({
        email: "user@example.com",
        password: "newpassword123",
      });
      expect(loginResult.status).toBe(200);
    });

    it("rejects old password after reset", async () => {
      await handleResetPassword({
        token: resetToken,
        password: "newpassword123",
      });

      const loginResult = await handleLogin({
        email: "user@example.com",
        password: "oldpassword",
      });
      expect(loginResult.status).toBe(401);
    });

    it("invalidates token after use", async () => {
      await handleResetPassword({
        token: resetToken,
        password: "newpassword123",
      });

      const result = await handleResetPassword({
        token: resetToken,
        password: "anotherpassword",
      });
      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toContain("Invalid or expired");
      }
    });

    it("returns 400 for invalid token", async () => {
      const result = await handleResetPassword({
        token: "bogustoken",
        password: "newpassword123",
      });

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toContain("Invalid or expired");
      }
    });

    it("returns 400 for short password", async () => {
      const result = await handleResetPassword({
        token: resetToken,
        password: "short",
      });

      expect(result.status).toBe(400);
      if ("error" in result.body) {
        expect(result.body.error).toBe("Validation failed");
      }
    });
  });
});
