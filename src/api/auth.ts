import { z } from "zod";
import crypto from "node:crypto";
import { User, CreateUserInput } from "../models/User.js";
import { hashPassword, verifyPassword } from "../utils/password.js";
import { generateToken } from "../services/token.js";
import { sendResetEmail } from "../services/email.js";

// --- Zod Schemas ---

export const registerSchema = z.object({
  email: z.string().email("Invalid email address"),
  password: z.string().min(8, "Password must be at least 8 characters"),
});

export const loginSchema = z.object({
  email: z.string().email("Invalid email address"),
  password: z.string().min(1, "Password is required"),
});

export const forgotPasswordSchema = z.object({
  email: z.string().email("Invalid email address"),
});

export const resetPasswordSchema = z.object({
  token: z.string().min(1, "Reset token is required"),
  password: z.string().min(8, "Password must be at least 8 characters"),
});

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
export type ForgotPasswordInput = z.infer<typeof forgotPasswordSchema>;
export type ResetPasswordInput = z.infer<typeof resetPasswordSchema>;

// --- In-memory user store (to be replaced with real DB) ---

const users: Map<string, User> = new Map();
let nextId = 1;

export function clearUsers(): void {
  users.clear();
  nextId = 1;
}

export function findUserByEmail(email: string): User | undefined {
  for (const user of users.values()) {
    if (user.email === email) {
      return user;
    }
  }
  return undefined;
}

export function findUserById(id: string): User | undefined {
  return users.get(id);
}

export function createUser(input: CreateUserInput): User {
  const id = String(nextId++);
  const now = new Date();
  const user: User = {
    id,
    email: input.email,
    passwordHash: input.passwordHash,
    createdAt: now,
    updatedAt: now,
  };
  users.set(id, user);
  return user;
}

export function updateUserPassword(userId: string, newPasswordHash: string): User | undefined {
  const user = users.get(userId);
  if (!user) return undefined;
  user.passwordHash = newPasswordHash;
  user.updatedAt = new Date();
  return user;
}

// --- Password reset token store ---

interface ResetToken {
  userId: string;
  token: string;
  expiresAt: Date;
}

const resetTokens: Map<string, ResetToken> = new Map();
const RESET_TOKEN_EXPIRY_MS = 60 * 60 * 1000; // 1 hour

export function clearResetTokens(): void {
  resetTokens.clear();
}

export function getResetToken(token: string): ResetToken | undefined {
  return resetTokens.get(token);
}

function createResetToken(userId: string): string {
  const token = crypto.randomBytes(32).toString("hex");
  resetTokens.set(token, {
    userId,
    token,
    expiresAt: new Date(Date.now() + RESET_TOKEN_EXPIRY_MS),
  });
  return token;
}

// --- Route Handlers ---

export interface AuthResponse {
  token: string;
  user: { id: string; email: string };
}

export interface ErrorResponse {
  error: string;
  details?: Array<{ path: string; message: string }>;
}

export async function handleRegister(
  body: unknown,
): Promise<{ status: number; body: AuthResponse | ErrorResponse }> {
  const parsed = registerSchema.safeParse(body);
  if (!parsed.success) {
    return {
      status: 400,
      body: {
        error: "Validation failed",
        details: parsed.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
    };
  }

  const { email, password } = parsed.data;

  const existing = findUserByEmail(email);
  if (existing) {
    return {
      status: 409,
      body: { error: "Email already registered" },
    };
  }

  const passwordHash = await hashPassword(password);
  const user = createUser({ email, passwordHash });
  const token = generateToken(user.id, user.email);

  return {
    status: 201,
    body: {
      token,
      user: { id: user.id, email: user.email },
    },
  };
}

export async function handleLogin(
  body: unknown,
): Promise<{ status: number; body: AuthResponse | ErrorResponse }> {
  const parsed = loginSchema.safeParse(body);
  if (!parsed.success) {
    return {
      status: 400,
      body: {
        error: "Validation failed",
        details: parsed.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
    };
  }

  const { email, password } = parsed.data;

  const user = findUserByEmail(email);
  if (!user) {
    return {
      status: 401,
      body: { error: "Invalid email or password" },
    };
  }

  const valid = await verifyPassword(password, user.passwordHash);
  if (!valid) {
    return {
      status: 401,
      body: { error: "Invalid email or password" },
    };
  }

  const token = generateToken(user.id, user.email);

  return {
    status: 200,
    body: {
      token,
      user: { id: user.id, email: user.email },
    },
  };
}

// --- Password Reset Handlers ---

export interface MessageResponse {
  message: string;
}

export async function handleForgotPassword(
  body: unknown,
): Promise<{ status: number; body: MessageResponse | ErrorResponse }> {
  const parsed = forgotPasswordSchema.safeParse(body);
  if (!parsed.success) {
    return {
      status: 400,
      body: {
        error: "Validation failed",
        details: parsed.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
    };
  }

  const { email } = parsed.data;
  const user = findUserByEmail(email);

  // Always return success to prevent email enumeration
  if (!user) {
    return {
      status: 200,
      body: { message: "If that email is registered, a reset link has been sent" },
    };
  }

  const resetToken = createResetToken(user.id);
  await sendResetEmail(email, resetToken);

  return {
    status: 200,
    body: { message: "If that email is registered, a reset link has been sent" },
  };
}

export async function handleResetPassword(
  body: unknown,
): Promise<{ status: number; body: MessageResponse | ErrorResponse }> {
  const parsed = resetPasswordSchema.safeParse(body);
  if (!parsed.success) {
    return {
      status: 400,
      body: {
        error: "Validation failed",
        details: parsed.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
    };
  }

  const { token, password } = parsed.data;

  const resetEntry = resetTokens.get(token);
  if (!resetEntry) {
    return {
      status: 400,
      body: { error: "Invalid or expired reset token" },
    };
  }

  if (resetEntry.expiresAt < new Date()) {
    resetTokens.delete(token);
    return {
      status: 400,
      body: { error: "Invalid or expired reset token" },
    };
  }

  const newHash = await hashPassword(password);
  const updated = updateUserPassword(resetEntry.userId, newHash);
  if (!updated) {
    return {
      status: 400,
      body: { error: "User not found" },
    };
  }

  // Invalidate the used token
  resetTokens.delete(token);

  return {
    status: 200,
    body: { message: "Password has been reset successfully" },
  };
}
