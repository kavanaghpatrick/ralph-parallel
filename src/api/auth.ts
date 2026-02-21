import { z } from "zod";
import { User, CreateUserInput } from "../models/User.js";
import { hashPassword, verifyPassword } from "../utils/password.js";
import { generateToken } from "../services/token.js";

// --- Zod Schemas ---

export const registerSchema = z.object({
  email: z.string().email("Invalid email address"),
  password: z.string().min(8, "Password must be at least 8 characters"),
});

export const loginSchema = z.object({
  email: z.string().email("Invalid email address"),
  password: z.string().min(1, "Password is required"),
});

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;

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
