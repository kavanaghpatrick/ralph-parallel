import { verifyToken } from "../services/token.js";

export interface AuthenticatedUser {
  userId: string;
  email: string;
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

export function requireAuth(context: RequestContext): AuthResult | AuthError {
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
