import React, { useState, FormEvent } from 'react';

interface LoginFormProps {
  onSuccess?: (token: string) => void;
  onNavigateRegister?: () => void;
}

interface FormErrors {
  email?: string;
  password?: string;
  general?: string;
}

function validateEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

export function LoginForm({ onSuccess, onNavigateRegister }: LoginFormProps) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [errors, setErrors] = useState<FormErrors>({});
  const [loading, setLoading] = useState(false);

  function validate(): FormErrors {
    const errs: FormErrors = {};
    if (!email) {
      errs.email = 'Email is required';
    } else if (!validateEmail(email)) {
      errs.email = 'Invalid email format';
    }
    if (!password) {
      errs.password = 'Password is required';
    } else if (password.length < 8) {
      errs.password = 'Password must be at least 8 characters';
    }
    return errs;
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const validationErrors = validate();
    if (Object.keys(validationErrors).length > 0) {
      setErrors(validationErrors);
      return;
    }
    setErrors({});
    setLoading(true);

    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      });

      if (!response.ok) {
        const data = await response.json();
        setErrors({ general: data.message || 'Login failed' });
        return;
      }

      const data = await response.json();
      localStorage.setItem('token', data.token);
      onSuccess?.(data.token);
    } catch {
      setErrors({ general: 'Network error. Please try again.' });
    } finally {
      setLoading(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} aria-label="Login form" noValidate>
      <h2>Login</h2>

      {errors.general && (
        <div role="alert" className="error-message">
          {errors.general}
        </div>
      )}

      <div>
        <label htmlFor="login-email">Email</label>
        <input
          id="login-email"
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          disabled={loading}
        />
        {errors.email && <span className="field-error">{errors.email}</span>}
      </div>

      <div>
        <label htmlFor="login-password">Password</label>
        <input
          id="login-password"
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="Enter password"
          disabled={loading}
        />
        {errors.password && <span className="field-error">{errors.password}</span>}
      </div>

      <button type="submit" disabled={loading}>
        {loading ? 'Logging in...' : 'Login'}
      </button>

      {onNavigateRegister && (
        <p>
          Don't have an account?{' '}
          <button type="button" onClick={onNavigateRegister}>
            Register
          </button>
        </p>
      )}
    </form>
  );
}
