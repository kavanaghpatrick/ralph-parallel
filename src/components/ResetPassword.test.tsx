import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ResetPassword } from './ResetPassword.js';

describe('ResetPassword', () => {
  const defaultToken = 'reset-token-abc123';

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('renders password and confirm password fields', () => {
    render(<ResetPassword token={defaultToken} />);
    expect(screen.getByLabelText('New Password')).toBeDefined();
    expect(screen.getByLabelText('Confirm Password')).toBeDefined();
    expect(screen.getByRole('button', { name: 'Reset Password' })).toBeDefined();
  });

  it('shows error for empty fields', async () => {
    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));
    expect(screen.getByText('Password is required')).toBeDefined();
    expect(screen.getByText('Please confirm your password')).toBeDefined();
  });

  it('shows error for weak password - too short', async () => {
    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('New Password'), 'Aa1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Aa1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));
    expect(screen.getByText('Password must be at least 8 characters')).toBeDefined();
  });

  it('shows error for weak password - no uppercase', async () => {
    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('New Password'), 'password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));
    expect(screen.getByText('Password must contain an uppercase letter')).toBeDefined();
  });

  it('shows error when passwords do not match', async () => {
    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password2');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));
    expect(screen.getByText('Passwords do not match')).toBeDefined();
  });

  it('submits successfully and shows success message', async () => {
    const onSuccess = vi.fn();
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ message: 'Password reset' }),
    });

    render(<ResetPassword token={defaultToken} onSuccess={onSuccess} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));

    await waitFor(() => {
      expect(screen.getByText('Password Reset Successfully')).toBeDefined();
      expect(onSuccess).toHaveBeenCalled();
    });
  });

  it('sends token in the request body', async () => {
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({}),
    });

    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));

    await waitFor(() => {
      expect(global.fetch).toHaveBeenCalledWith('/api/auth/reset-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: defaultToken, password: 'Password1' }),
      });
    });
  });

  it('displays server error on failure', async () => {
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: false,
      json: () => Promise.resolve({ message: 'Token expired' }),
    });

    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));

    await waitFor(() => {
      expect(screen.getByText('Token expired')).toBeDefined();
    });
  });

  it('displays network error on fetch failure', async () => {
    global.fetch = vi.fn().mockRejectedValueOnce(new Error('Network error'));

    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));

    await waitFor(() => {
      expect(screen.getByText('Network error. Please try again.')).toBeDefined();
    });
  });

  it('shows loading state during submission', async () => {
    let resolvePromise: (value: unknown) => void;
    const pendingPromise = new Promise((resolve) => {
      resolvePromise = resolve;
    });
    global.fetch = vi.fn().mockReturnValueOnce(pendingPromise);

    render(<ResetPassword token={defaultToken} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));

    expect(screen.getByRole('button', { name: 'Resetting...' })).toBeDefined();

    resolvePromise!({ ok: true, json: () => Promise.resolve({}) });
  });

  it('shows login navigation on success when callback provided', async () => {
    const onNavigate = vi.fn();
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({}),
    });

    render(<ResetPassword token={defaultToken} onNavigateLogin={onNavigate} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('New Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Reset Password' }));

    await waitFor(() => {
      expect(screen.getByText('Go to Login')).toBeDefined();
    });
  });
});
