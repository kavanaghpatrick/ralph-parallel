import { describe, it, expect } from "vitest";
import type { User, CreateUserInput } from "./User.js";

describe("User model", () => {
  it("User interface has required fields", () => {
    const user: User = {
      id: "550e8400-e29b-41d4-a716-446655440000",
      email: "test@example.com",
      passwordHash: "$2b$12$hashedvalue",
      createdAt: new Date(),
      updatedAt: new Date(),
    };

    expect(user.id).toBeDefined();
    expect(user.email).toBe("test@example.com");
    expect(user.passwordHash).toBeDefined();
    expect(user.createdAt).toBeInstanceOf(Date);
    expect(user.updatedAt).toBeInstanceOf(Date);
  });

  it("CreateUserInput only requires email and passwordHash", () => {
    const input: CreateUserInput = {
      email: "new@example.com",
      passwordHash: "$2b$12$hashedvalue",
    };

    expect(input.email).toBe("new@example.com");
    expect(input.passwordHash).toBeDefined();
  });
});
