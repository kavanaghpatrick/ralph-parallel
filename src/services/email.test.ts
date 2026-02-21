import { describe, it, expect, beforeEach } from "vitest";
import {
  sendEmail,
  sendResetEmail,
  getSentEmails,
  clearSentEmails,
} from "./email.js";

describe("email service", () => {
  beforeEach(() => {
    clearSentEmails();
  });

  describe("sendEmail", () => {
    it("records sent email", async () => {
      await sendEmail({ to: "a@b.com", subject: "Test", body: "Hello" });
      const emails = getSentEmails();
      expect(emails).toHaveLength(1);
      expect(emails[0].to).toBe("a@b.com");
      expect(emails[0].subject).toBe("Test");
    });

    it("accumulates multiple emails", async () => {
      await sendEmail({ to: "a@b.com", subject: "First", body: "1" });
      await sendEmail({ to: "c@d.com", subject: "Second", body: "2" });
      expect(getSentEmails()).toHaveLength(2);
    });
  });

  describe("sendResetEmail", () => {
    it("sends email with reset link", async () => {
      await sendResetEmail("user@example.com", "abc123");
      const emails = getSentEmails();
      expect(emails).toHaveLength(1);
      expect(emails[0].to).toBe("user@example.com");
      expect(emails[0].subject).toBe("Password Reset Request");
      expect(emails[0].body).toContain("abc123");
      expect(emails[0].body).toContain("reset-password?token=abc123");
    });

    it("includes expiry warning in body", async () => {
      await sendResetEmail("user@example.com", "token");
      const emails = getSentEmails();
      expect(emails[0].body).toContain("expires in 1 hour");
    });
  });

  describe("clearSentEmails", () => {
    it("clears all recorded emails", async () => {
      await sendEmail({ to: "a@b.com", subject: "Test", body: "Hello" });
      expect(getSentEmails()).toHaveLength(1);
      clearSentEmails();
      expect(getSentEmails()).toHaveLength(0);
    });
  });
});
