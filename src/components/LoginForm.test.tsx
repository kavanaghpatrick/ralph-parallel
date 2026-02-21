import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { LoginForm } from './LoginForm.js';

describe('LoginForm', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    localStorage.clear();
  });

  it('renders email and password fields', () => {
    render(<LoginForm />);
    expect(screen.getByLabelText('Email')).toBeDefined();
    expect(screen.getByLabelText('Password')).toBeDefined();
    expect(screen.getByRole('button', { name: 'Login' })).toBeDefined();
  });

  it('shows error for empty email', async () => {
    render(<LoginForm />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: 'Login' }));
    expect(screen.getByText('Email is required')).toBeDefined();
  });

  it('shows error for invalid email format', async () => {
    render(<LoginForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'notanemail');
    await user.type(screen.getByLabelText('Password'), 'password123');
    await user.click(screen.getByRole('button', { name: 'Login' }));
    expect(screen.getByText('Invalid email format')).toBeDefined();
  });

  it('shows error for short password', async () => {
    render(<LoginForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'short');
    await user.click(screen.getByRole('button', { name: 'Login' }));
    expect(screen.getByText('Password must be at least 8 characters')).toBeDefined();
  });

  it('submits and stores token on success', async () => {
    const mockToken = 'jwt-token-123';
    const onSuccess = vi.fn();

    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ token: mockToken }),
    });

    render(<LoginForm onSuccess={onSuccess} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'password123');
    await user.click(screen.getByRole('button', { name: 'Login' }));

    await waitFor(() => {
      expect(localStorage.getItem('token')).toBe(mockToken);
      expect(onSuccess).toHaveBeenCalledWith(mockToken);
    });
  });

  it('displays server error message on failed login', async () => {
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: false,
      json: () => Promise.resolve({ message: 'Invalid credentials' }),
    });

    render(<LoginForm />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'password123');
    await user.click(screen.getByRole('button', { name: 'Login' }));

    await waitFor(() => {
      expect(screen.getByText('Invalid credentials')).toBeDefined();
    });
  });

  it('displays network error on fetch failure', async () => {
    global.fetch = vi.fn().mockRejectedValueOnce(new Error('Network error'));

    render(<LoginForm />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'password123');
    await user.click(screen.getByRole('button', { name: 'Login' }));

    await waitFor(() => {
      expect(screen.getByText('Network error. Please try again.')).toBeDefined();
    });
  });

  it('disables inputs and button during loading', async () => {
    let resolvePromise: (value: unknown) => void;
    const pendingPromise = new Promise((resolve) => {
      resolvePromise = resolve;
    });

    global.fetch = vi.fn().mockReturnValueOnce(pendingPromise);

    render(<LoginForm />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'password123');
    await user.click(screen.getByRole('button', { name: 'Login' }));

    expect(screen.getByRole('button', { name: 'Logging in...' })).toBeDefined();
    expect(screen.getByLabelText('Email')).toHaveProperty('disabled', true);
    expect(screen.getByLabelText('Password')).toHaveProperty('disabled', true);

    resolvePromise!({ ok: true, json: () => Promise.resolve({ token: 'tok' }) });
  });

  it('renders register navigation when callback provided', () => {
    const onNavigate = vi.fn();
    render(<LoginForm onNavigateRegister={onNavigate} />);
    expect(screen.getByText('Register')).toBeDefined();
  });
});
