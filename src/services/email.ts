export interface EmailMessage {
  to: string;
  subject: string;
  body: string;
}

// Sent emails log for testing
const sentEmails: EmailMessage[] = [];

export function getSentEmails(): EmailMessage[] {
  return [...sentEmails];
}

export function clearSentEmails(): void {
  sentEmails.length = 0;
}

export async function sendEmail(message: EmailMessage): Promise<void> {
  sentEmails.push(message);
}

export async function sendResetEmail(
  to: string,
  resetToken: string,
): Promise<void> {
  const resetUrl = `${process.env.APP_URL || "http://localhost:3000"}/reset-password?token=${resetToken}`;
  await sendEmail({
    to,
    subject: "Password Reset Request",
    body: `You requested a password reset. Click the link below to reset your password:\n\n${resetUrl}\n\nThis link expires in 1 hour. If you did not request this, ignore this email.`,
  });
}
