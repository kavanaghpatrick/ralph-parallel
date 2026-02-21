export interface Session {
  id: string;
  userId: string;
  token: string;
  expiresAt: Date;
  deviceInfo: string | null;
  createdAt: Date;
}

export interface CreateSessionInput {
  userId: string;
  token: string;
  expiresAt: Date;
  deviceInfo?: string;
}

// In-memory session store (replace with database in production)
const sessions = new Map<string, Session>();

export function createSession(input: CreateSessionInput): Session {
  const session: Session = {
    id: crypto.randomUUID(),
    userId: input.userId,
    token: input.token,
    expiresAt: input.expiresAt,
    deviceInfo: input.deviceInfo ?? null,
    createdAt: new Date(),
  };
  sessions.set(session.id, session);
  return session;
}

export function findSessionByToken(token: string): Session | undefined {
  for (const session of sessions.values()) {
    if (session.token === token && session.expiresAt > new Date()) {
      return session;
    }
  }
  return undefined;
}

export function invalidateSession(sessionId: string): boolean {
  return sessions.delete(sessionId);
}

export function invalidateUserSessions(userId: string): number {
  let count = 0;
  for (const [id, session] of sessions.entries()) {
    if (session.userId === userId) {
      sessions.delete(id);
      count++;
    }
  }
  return count;
}

export function getActiveSessions(userId: string): Session[] {
  const now = new Date();
  return Array.from(sessions.values()).filter(
    (s) => s.userId === userId && s.expiresAt > now
  );
}

// For testing
export function clearSessions(): void {
  sessions.clear();
}
