import { verifyToken } from "../services/token.js";
import { findSessionByToken, invalidateSession } from "../models/Session.js";

export interface AuthenticatedUser {
  userId: string;
  email: string;
  sessionId?: string;
}

export interface RequestContext {
  headers: Record<string, string | undefined>;
}

export interface AuthResult {
  authenticated: true;
  user: AuthenticatedUser;
}

export interface AuthError {
  authenticated: false;
  status: 401;
  body: { error: string };
}

export interface RequireAuthOptions {
  validateSession?: boolean;
}

export function requireAuth(
  context: RequestContext,
  options: RequireAuthOptions = {},
): AuthResult | AuthError {
  const authHeader = context.headers["authorization"];

  if (!authHeader) {
    return {
      authenticated: false,
      status: 401,
      body: { error: "Missing Authorization header" },
    };
  }

  const parts = authHeader.split(" ");
  if (parts.length !== 2 || parts[0] !== "Bearer") {
    return {
      authenticated: false,
      status: 401,
      body: { error: "Invalid Authorization header format. Expected: Bearer <token>" },
    };
  }

  const token = parts[1];

  try {
    const payload = verifyToken(token);

    // Optionally validate the token has an active session
    if (options.validateSession) {
      const session = findSessionByToken(token);
      if (!session) {
        return {
          authenticated: false,
          status: 401,
          body: { error: "Session expired or invalidated" },
        };
      }
      return {
        authenticated: true,
        user: {
          userId: payload.userId,
          email: payload.email,
          sessionId: session.id,
        },
      };
    }

    return {
      authenticated: true,
      user: {
        userId: payload.userId,
        email: payload.email,
      },
    };
  } catch {
    return {
      authenticated: false,
      status: 401,
      body: { error: "Invalid or expired token" },
    };
  }
}

export function handleLogout(
  context: RequestContext,
): { status: number; body: { message: string } | { error: string } } {
  const authResult = requireAuth(context, { validateSession: true });

  if (!authResult.authenticated) {
    return { status: 401, body: { error: "Not authenticated" } };
  }

  if (authResult.user.sessionId) {
    invalidateSession(authResult.user.sessionId);
  }

  return { status: 200, body: { message: "Logged out successfully" } };
}
