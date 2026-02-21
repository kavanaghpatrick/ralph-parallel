import React, { useState, FormEvent } from 'react';

interface ResetPasswordProps {
  token: string;
  onSuccess?: () => void;
  onNavigateLogin?: () => void;
}

interface FormErrors {
  password?: string;
  confirmPassword?: string;
  general?: string;
}

function validatePasswordStrength(password: string): string | null {
  if (password.length < 8) return 'Password must be at least 8 characters';
  if (!/[A-Z]/.test(password)) return 'Password must contain an uppercase letter';
  if (!/[a-z]/.test(password)) return 'Password must contain a lowercase letter';
  if (!/[0-9]/.test(password)) return 'Password must contain a number';
  return null;
}

export function ResetPassword({ token, onSuccess, onNavigateLogin }: ResetPasswordProps) {
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [errors, setErrors] = useState<FormErrors>({});
  const [loading, setLoading] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  function validate(): FormErrors {
    const errs: FormErrors = {};
    if (!password) {
      errs.password = 'Password is required';
    } else {
      const strengthError = validatePasswordStrength(password);
      if (strengthError) errs.password = strengthError;
    }
    if (!confirmPassword) {
      errs.confirmPassword = 'Please confirm your password';
    } else if (password !== confirmPassword) {
      errs.confirmPassword = 'Passwords do not match';
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
      const response = await fetch('/api/auth/reset-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token, password }),
      });

      if (!response.ok) {
        const data = await response.json();
        setErrors({ general: data.message || 'Reset failed' });
        return;
      }

      setSubmitted(true);
      onSuccess?.();
    } catch {
      setErrors({ general: 'Network error. Please try again.' });
    } finally {
      setLoading(false);
    }
  }

  if (submitted) {
    return (
      <div aria-label="Reset password success">
        <h2>Password Reset Successfully</h2>
        <p>Your password has been updated. You can now log in with your new password.</p>
        {onNavigateLogin && (
          <button type="button" onClick={onNavigateLogin}>
            Go to Login
          </button>
        )}
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} aria-label="Reset password form" noValidate>
      <h2>Reset Password</h2>

      {errors.general && (
        <div role="alert" className="error-message">
          {errors.general}
        </div>
      )}

      <div>
        <label htmlFor="reset-password">New Password</label>
        <input
          id="reset-password"
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="Enter new password"
          disabled={loading}
        />
        {errors.password && <span className="field-error">{errors.password}</span>}
      </div>

      <div>
        <label htmlFor="reset-confirm-password">Confirm Password</label>
        <input
          id="reset-confirm-password"
          type="password"
          value={confirmPassword}
          onChange={(e) => setConfirmPassword(e.target.value)}
          placeholder="Confirm new password"
          disabled={loading}
        />
        {errors.confirmPassword && (
          <span className="field-error">{errors.confirmPassword}</span>
        )}
      </div>

      <button type="submit" disabled={loading}>
        {loading ? 'Resetting...' : 'Reset Password'}
      </button>
    </form>
  );
}
