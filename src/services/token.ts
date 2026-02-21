import jwt from "jsonwebtoken";

const DEFAULT_SECRET = "dev-secret-change-in-production";
const DEFAULT_EXPIRY = "24h";

export interface TokenPayload {
  userId: string;
  email: string;
}

export interface DecodedToken extends TokenPayload {
  iat: number;
  exp: number;
}

function getSecret(): string {
  return process.env.JWT_SECRET || DEFAULT_SECRET;
}

export function generateToken(userId: string, email: string): string {
  const payload: TokenPayload = { userId, email };
  return jwt.sign(payload, getSecret(), { expiresIn: DEFAULT_EXPIRY });
}

export function verifyToken(token: string): DecodedToken {
  const decoded = jwt.verify(token, getSecret());
  return decoded as DecodedToken;
}
