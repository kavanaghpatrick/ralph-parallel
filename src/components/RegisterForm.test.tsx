import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { RegisterForm } from './RegisterForm.js';

describe('RegisterForm', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('renders email, password, and confirm password fields', () => {
    render(<RegisterForm />);
    expect(screen.getByLabelText('Email')).toBeDefined();
    expect(screen.getByLabelText('Password')).toBeDefined();
    expect(screen.getByLabelText('Confirm Password')).toBeDefined();
    expect(screen.getByRole('button', { name: 'Register' })).toBeDefined();
  });

  it('shows error for empty fields', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Email is required')).toBeDefined();
    expect(screen.getByText('Password is required')).toBeDefined();
    expect(screen.getByText('Please confirm your password')).toBeDefined();
  });

  it('shows error for invalid email', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'bademail');
    await user.type(screen.getByLabelText('Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Invalid email format')).toBeDefined();
  });

  it('shows error for weak password - no uppercase', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'password1');
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Password must contain an uppercase letter')).toBeDefined();
  });

  it('shows error for weak password - no lowercase', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'PASSWORD1');
    await user.type(screen.getByLabelText('Confirm Password'), 'PASSWORD1');
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Password must contain a lowercase letter')).toBeDefined();
  });

  it('shows error for weak password - no number', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Passwordx');
    await user.type(screen.getByLabelText('Confirm Password'), 'Passwordx');
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Password must contain a number')).toBeDefined();
  });

  it('shows error for short password', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Aa1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Aa1');
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Password must be at least 8 characters')).toBeDefined();
  });

  it('shows error when passwords do not match', async () => {
    render(<RegisterForm />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password2');
    await user.click(screen.getByRole('button', { name: 'Register' }));
    expect(screen.getByText('Passwords do not match')).toBeDefined();
  });

  it('submits successfully and calls onSuccess', async () => {
    const onSuccess = vi.fn();

    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ message: 'User created' }),
    });

    render(<RegisterForm onSuccess={onSuccess} />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Register' }));

    await waitFor(() => {
      expect(onSuccess).toHaveBeenCalled();
    });
  });

  it('displays server error message on failed registration', async () => {
    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: false,
      json: () => Promise.resolve({ message: 'Email already in use' }),
    });

    render(<RegisterForm />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Register' }));

    await waitFor(() => {
      expect(screen.getByText('Email already in use')).toBeDefined();
    });
  });

  it('displays network error on fetch failure', async () => {
    global.fetch = vi.fn().mockRejectedValueOnce(new Error('Network error'));

    render(<RegisterForm />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Register' }));

    await waitFor(() => {
      expect(screen.getByText('Network error. Please try again.')).toBeDefined();
    });
  });

  it('disables inputs during loading', async () => {
    let resolvePromise: (value: unknown) => void;
    const pendingPromise = new Promise((resolve) => {
      resolvePromise = resolve;
    });

    global.fetch = vi.fn().mockReturnValueOnce(pendingPromise);

    render(<RegisterForm />);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText('Email'), 'test@example.com');
    await user.type(screen.getByLabelText('Password'), 'Password1');
    await user.type(screen.getByLabelText('Confirm Password'), 'Password1');
    await user.click(screen.getByRole('button', { name: 'Register' }));

    expect(screen.getByRole('button', { name: 'Registering...' })).toBeDefined();
    expect(screen.getByLabelText('Email')).toHaveProperty('disabled', true);

    resolvePromise!({ ok: true, json: () => Promise.resolve({}) });
  });

  it('renders login navigation when callback provided', () => {
    const onNavigate = vi.fn();
    render(<RegisterForm onNavigateLogin={onNavigate} />);
    expect(screen.getByText('Login')).toBeDefined();
  });
});
