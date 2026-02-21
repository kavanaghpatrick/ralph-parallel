import { describe, it, expect, beforeEach } from "vitest";
import {
  createSession,
  findSessionByToken,
  invalidateSession,
  invalidateUserSessions,
  getActiveSessions,
  clearSessions,
} from "./Session.js";

describe("session management", () => {
  beforeEach(() => {
    clearSessions();
  });

  it("creates a session with correct fields", () => {
    const session = createSession({
      userId: "user-1",
      token: "jwt-token-abc",
      expiresAt: new Date(Date.now() + 86400000),
      deviceInfo: "Chrome on macOS",
    });

    expect(session.id).toBeDefined();
    expect(session.userId).toBe("user-1");
    expect(session.token).toBe("jwt-token-abc");
    expect(session.deviceInfo).toBe("Chrome on macOS");
    expect(session.createdAt).toBeInstanceOf(Date);
  });

  it("finds session by token", () => {
    createSession({
      userId: "user-1",
      token: "find-me-token",
      expiresAt: new Date(Date.now() + 86400000),
    });

    const found = findSessionByToken("find-me-token");
    expect(found).toBeDefined();
    expect(found!.token).toBe("find-me-token");
  });

  it("returns undefined for expired session", () => {
    createSession({
      userId: "user-1",
      token: "expired-token",
      expiresAt: new Date(Date.now() - 1000), // already expired
    });

    const found = findSessionByToken("expired-token");
    expect(found).toBeUndefined();
  });

  it("returns undefined for unknown token", () => {
    const found = findSessionByToken("nonexistent");
    expect(found).toBeUndefined();
  });

  it("invalidates a session by ID", () => {
    const session = createSession({
      userId: "user-1",
      token: "to-invalidate",
      expiresAt: new Date(Date.now() + 86400000),
    });

    const deleted = invalidateSession(session.id);
    expect(deleted).toBe(true);
    expect(findSessionByToken("to-invalidate")).toBeUndefined();
  });

  it("invalidates all sessions for a user", () => {
    createSession({
      userId: "user-1",
      token: "token-a",
      expiresAt: new Date(Date.now() + 86400000),
    });
    createSession({
      userId: "user-1",
      token: "token-b",
      expiresAt: new Date(Date.now() + 86400000),
    });
    createSession({
      userId: "user-2",
      token: "token-c",
      expiresAt: new Date(Date.now() + 86400000),
    });

    const count = invalidateUserSessions("user-1");
    expect(count).toBe(2);
    expect(findSessionByToken("token-a")).toBeUndefined();
    expect(findSessionByToken("token-b")).toBeUndefined();
    expect(findSessionByToken("token-c")).toBeDefined();
  });

  it("gets active sessions for a user", () => {
    createSession({
      userId: "user-1",
      token: "active-1",
      expiresAt: new Date(Date.now() + 86400000),
    });
    createSession({
      userId: "user-1",
      token: "expired-1",
      expiresAt: new Date(Date.now() - 1000),
    });

    const active = getActiveSessions("user-1");
    expect(active).toHaveLength(1);
    expect(active[0].token).toBe("active-1");
  });

  it("creates session with null deviceInfo when not provided", () => {
    const session = createSession({
      userId: "user-1",
      token: "no-device",
      expiresAt: new Date(Date.now() + 86400000),
    });

    expect(session.deviceInfo).toBeNull();
  });
});
