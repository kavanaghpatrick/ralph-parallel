# Tasks: User Authentication

## Phase 1: Core Implementation

- [x] 1.1 [P] Create user model and database schema
  - **Files**: `src/models/User.ts`, `src/db/migrations/001_users.sql`
  - **Do**:
    1. Define User model with id, email, passwordHash, createdAt, updatedAt
    2. Create SQL migration for users table
    3. Add unique constraint on email
  - **Done when**: Migration runs successfully and model is importable
  - **Verify**: `npm run db:migrate && npm test -- --grep "User model"`
  - **Commit**: `feat: add User model and database migration`

- [x] 1.2 [P] Implement password hashing utility
  - **Files**: `src/utils/password.ts`, `src/utils/password.test.ts`
  - **Do**:
    1. Create hashPassword(plain) using bcrypt with salt rounds=12
    2. Create verifyPassword(plain, hash) returning boolean
    3. Write unit tests for both functions
  - **Done when**: Tests pass for hash/verify round-trip
  - **Verify**: `npm test -- --grep "password"`
  - **Commit**: `feat: add password hashing utilities`

- [x] 1.3 [P] Build JWT token service
  - **Files**: `src/services/token.ts`, `src/services/token.test.ts`
  - **Do**:
    1. Create generateToken(userId, email) with 24h expiry
    2. Create verifyToken(token) returning payload or throwing
    3. Use RS256 algorithm with configurable secret
    4. Write tests for generation, verification, and expiry
  - **Done when**: Token round-trip works and expired tokens are rejected
  - **Verify**: `npm test -- --grep "token"`
  - **Commit**: `feat: add JWT token service`

- [x] 1.4 [P] Create auth API routes (register + login)
  - **Files**: `src/api/auth.ts`, `src/api/auth.test.ts`
  - **Do**:
    1. POST /api/auth/register - validate input, hash password, create user, return token
    2. POST /api/auth/login - find user, verify password, return token
    3. Add input validation with zod schemas
    4. Write integration tests
  - **Done when**: Register creates user and returns JWT, login validates credentials
  - **Verify**: `npm test -- --grep "auth routes"`
  - **Commit**: `feat: add register and login API routes`

- [x] 1.5 [P] Build auth middleware
  - **Files**: `src/api/middleware.ts`, `src/api/middleware.test.ts`
  - **Do**:
    1. Create requireAuth middleware that extracts JWT from Authorization header
    2. Verify token and attach user to request context
    3. Return 401 for missing/invalid tokens
    4. Write middleware tests
  - **Done when**: Protected routes reject unauthenticated requests
  - **Verify**: `npm test -- --grep "middleware"`
  - **Commit**: `feat: add auth middleware`

- [x] 1.6 [P] Create login form component
  - **Files**: `src/components/LoginForm.tsx`, `src/components/LoginForm.test.tsx`
  - **Do**:
    1. Build login form with email + password fields
    2. Add client-side validation (email format, password min length)
    3. Handle submit → POST /api/auth/login
    4. Store JWT in localStorage on success
    5. Write component tests
  - **Done when**: Form submits and stores token
  - **Verify**: `npm test -- --grep "LoginForm"`
  - **Commit**: `feat: add LoginForm component`

- [x] 1.7 [P] Create registration form component
  - **Files**: `src/components/RegisterForm.tsx`, `src/components/RegisterForm.test.tsx`
  - **Do**:
    1. Build registration form with email, password, confirmPassword
    2. Validate password match and strength requirements
    3. Handle submit → POST /api/auth/register
    4. Redirect to login on success
    5. Write component tests
  - **Done when**: Form submits and user can register
  - **Verify**: `npm test -- --grep "RegisterForm"`
  - **Commit**: `feat: add RegisterForm component`

- [ ] 1.8 [VERIFY] Phase 1 integration verification
  - **Files**: none
  - **Do**:
    1. Run full test suite
    2. Verify register → login → access protected route flow works end-to-end
    3. Check no TypeScript errors
  - **Done when**: All tests pass, e2e flow works
  - **Verify**: `npm test && npm run typecheck`
  - **Commit**: none

## Phase 2: Enhanced Features

- [ ] 2.1 Add password reset flow (API)
  - **Files**: `src/api/auth.ts`, `src/services/email.ts`, `src/services/email.test.ts`
  - **Do**:
    1. POST /api/auth/forgot-password - generate reset token, send email
    2. POST /api/auth/reset-password - validate token, update password
    3. Create email service with sendResetEmail function
    4. Write tests
  - **Done when**: Reset flow generates token and mock email sends
  - **Verify**: `npm test -- --grep "password reset"`
  - **Commit**: `feat: add password reset API flow`

- [x] 2.2 Add password reset UI
  - **Files**: `src/components/ForgotPassword.tsx`, `src/components/ResetPassword.tsx`
  - **Do**:
    1. Build forgot-password form (email input → submit)
    2. Build reset-password form (new password + confirm → submit with token)
    3. Add success/error states
  - **Done when**: UI forms submit to correct API endpoints
  - **Verify**: `npm test -- --grep "ForgotPassword|ResetPassword"`
  - **Commit**: `feat: add password reset UI components`

- [ ] 2.3 Add session management
  - **Files**: `src/models/Session.ts`, `src/db/migrations/002_sessions.sql`, `src/api/middleware.ts`
  - **Do**:
    1. Create Session model with userId, token, expiresAt, deviceInfo
    2. Migration for sessions table
    3. Update middleware to check session validity
    4. Add logout endpoint that invalidates session
  - **Done when**: Sessions are tracked and logout works
  - **Verify**: `npm test -- --grep "session"`
  - **Commit**: `feat: add session management`

- [ ] 2.4 [VERIFY] Phase 2 integration verification
  - **Files**: none
  - **Do**:
    1. Run full test suite
    2. Test password reset e2e flow
    3. Test session create → use → logout → reject flow
  - **Done when**: All phase 2 features verified
  - **Verify**: `npm test && npm run typecheck`
  - **Commit**: none
