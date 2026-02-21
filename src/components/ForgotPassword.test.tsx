import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ForgotPassword } from './ForgotPassword.js';

describe('ForgotPassword', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('renders email field and submit button', () => {
    render(<ForgotPassword />);
    expect(screen.getByLabelText('Email')).toBeDefined();
    expect(screen.getByRole('button', { name: 'Send Reset Link' })).toBeDefined();
  });

  it('shows error for empty email', async () => {
    render(<ForgotPassword />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: 'Send Reset Link' }));
    expect(screen.getByText('Email is required')).toBeDefined();
  });

  it('shows error for invalid email format', async () => {
    render(<ForgotPassword />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'bademail');
    await user.click(screen.getByRole('button', { name: 'Send Reset Link' }));
    expect(screen.getByText('Invalid email format')).toBeDefined();
  });

  it('submits successfully and shows success message', async () => {
    const onSuccess = vi.fn();
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ message: 'Reset email sent' }),
    });

    render(<ForgotPassword onSuccess={onSuccess} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.click(screen.getByRole('button', { name: 'Send Reset Link' }));

    await waitFor(() => {
      expect(screen.getByText(/If an account exists for test@example.com/)).toBeDefined();
      expect(onSuccess).toHaveBeenCalled();
    });
  });

  it('displays server error on failure', async () => {
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: false,
      json: () => Promise.resolve({ message: 'Rate limit exceeded' }),
    });

    render(<ForgotPassword />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.click(screen.getByRole('button', { name: 'Send Reset Link' }));

    await waitFor(() => {
      expect(screen.getByText('Rate limit exceeded')).toBeDefined();
    });
  });

  it('displays network error on fetch failure', async () => {
    global.fetch = vi.fn().mockRejectedValueOnce(new Error('Network error'));

    render(<ForgotPassword />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.click(screen.getByRole('button', { name: 'Send Reset Link' }));

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

    render(<ForgotPassword />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.click(screen.getByRole('button', { name: 'Send Reset Link' }));

    expect(screen.getByRole('button', { name: 'Sending...' })).toBeDefined();
    expect(screen.getByLabelText('Email')).toHaveProperty('disabled', true);

    resolvePromise!({ ok: true, json: () => Promise.resolve({}) });
  });

  it('renders login navigation when callback provided', () => {
    const onNavigate = vi.fn();
    render(<ForgotPassword onNavigateLogin={onNavigate} />);
    expect(screen.getByText('Login')).toBeDefined();
  });
});
