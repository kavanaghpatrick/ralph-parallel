import React, { useState, FormEvent } from 'react';

interface ForgotPasswordProps {
  onSuccess?: () => void;
  onNavigateLogin?: () => void;
}

function validateEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

export function ForgotPassword({ onSuccess, onNavigateLogin }: ForgotPasswordProps) {
  const [email, setEmail] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();

    if (!email) {
      setError('Email is required');
      return;
    }
    if (!validateEmail(email)) {
      setError('Invalid email format');
      return;
    }

    setError('');
    setLoading(true);

    try {
      const response = await fetch('/api/auth/forgot-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });

      if (!response.ok) {
        const data = await response.json();
        setError(data.message || 'Request failed');
        return;
      }

      setSubmitted(true);
      onSuccess?.();
    } catch {
      setError('Network error. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  if (submitted) {
    return (
      <div aria-label="Forgot password success">
        <h2>Check Your Email</h2>
        <p>If an account exists for {email}, we sent a password reset link.</p>
        {onNavigateLogin && (
          <button type="button" onClick={onNavigateLogin}>
            Back to Login
          </button>
        )}
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} aria-label="Forgot password form" noValidate>
      <h2>Forgot Password</h2>

      {error && (
        <div role="alert" className="error-message">
          {error}
        </div>
      )}

      <div>
        <label htmlFor="forgot-email">Email</label>
        <input
          id="forgot-email"
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          disabled={loading}
        />
      </div>

      <button type="submit" disabled={loading}>
        {loading ? 'Sending...' : 'Send Reset Link'}
      </button>

      {onNavigateLogin && (
        <p>
          Remember your password?{' '}
          <button type="button" onClick={onNavigateLogin}>
            Login
          </button>
        </p>
      )}
    </form>
  );
}
