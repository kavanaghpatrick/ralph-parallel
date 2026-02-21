import { describe, it, expect } from "vitest";
import { hashPassword, verifyPassword } from "./password.js";

describe("password utilities", () => {
  it("hashPassword returns a bcrypt hash", async () => {
    const hash = await hashPassword("mySecret123");
    expect(hash).toBeDefined();
    expect(hash).not.toBe("mySecret123");
    expect(hash.startsWith("$2b$12$")).toBe(true);
  });

  it("verifyPassword returns true for correct password", async () => {
    const hash = await hashPassword("correctPassword");
    const result = await verifyPassword("correctPassword", hash);
    expect(result).toBe(true);
  });

  it("verifyPassword returns false for incorrect password", async () => {
    const hash = await hashPassword("correctPassword");
    const result = await verifyPassword("wrongPassword", hash);
    expect(result).toBe(false);
  });

  it("hashPassword produces different hashes for same input (unique salts)", async () => {
    const hash1 = await hashPassword("samePassword");
    const hash2 = await hashPassword("samePassword");
    expect(hash1).not.toBe(hash2);
  });
});
