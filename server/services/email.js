const nodemailer = require('nodemailer');
const config = require('../config');

const SENDGRID_API_URL = 'https://api.sendgrid.com/v3/mail/send';

let smtpTransport = null;

const parseFrom = () => {
  const raw = config.email.from || `ZELDA <${config.email.user}>`;
  const m = raw.match(/^(.*?)\s*<([^>]+)>\s*$/);
  if (m) return { name: m[1].trim(), email: m[2].trim() };
  return { name: 'ZELDA', email: raw.trim() };
};

const isSmtpConfigured = () => {
  return !!(config.email.smtpEnabled && config.email.host && config.email.user && config.email.pass);
};

const isBrevoConfigured = () => {
  return !!(config.email.brevoApiKey && (config.email.brevoSenderEmail || config.email.user));
};

const isEmailConfigured = () => {
  return !!(config.email.sendgridApiKey || isBrevoConfigured() || isSmtpConfigured());
};

const getSmtpTransport = () => {
  if (!smtpTransport) {
    const port = Number(config.email.port) || 587;
    smtpTransport = nodemailer.createTransport({
      host: config.email.host,
      port,
      secure: port === 465,
      auth: {
        user: config.email.user,
        pass: config.email.pass
      },
      connectionTimeout: 15000,
      greetingTimeout: 15000,
      socketTimeout: 20000
    });
  }
  return smtpTransport;
};

const sendViaSMTP = async (to, subject, html) => {
  if (!isSmtpConfigured()) {
    return { success: false, error: 'SMTP not configured' };
  }

  const recipients = Array.isArray(to)
    ? to.map(t => (typeof t === 'string' ? t : t.email)).join(', ')
    : to;

  try {
    const info = await getSmtpTransport().sendMail({
      from: config.email.from || config.email.user,
      to: recipients,
      subject,
      html
    });
    console.log(`📧 Email sent to ${recipients} via SMTP (${info.messageId || 'accepted'})`);
    return { success: true };
  } catch (error) {
    console.error('SMTP send error:', error.message);
    return { success: false, error: error.message };
  }
};

const sendViaSendGrid = async (to, subject, html) => {
  if (!config.email.sendgridApiKey) {
    console.warn('⚠️ Email not configured - cannot send');
    return { success: false, error: 'Email not configured' };
  }

  const recipients = Array.isArray(to)
    ? to.map(t => (typeof t === 'string' ? { email: t } : t))
    : [{ email: to }];

  const payload = {
    personalizations: [{ to: recipients }],
    from: parseFrom(),
    subject,
    content: [{ type: 'text/html', value: html }]
  };

  try {
    const response = await fetch(SENDGRID_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.email.sendgridApiKey}`
      },
      body: JSON.stringify(payload)
    });

    if (response.status === 202) {
      console.log(`📧 Email sent to ${to} via SendGrid`);
      return { success: true };
    }

    const body = await response.text();
    console.error(`Email send error: SendGrid ${response.status}: ${body}`);
    return { success: false, error: `SendGrid ${response.status}: ${body}` };
  } catch (error) {
    console.error('Email send error:', error.message);
    return { success: false, error: error.message };
  }
};

const sendViaBrevo = async (to, subject, html) => {
  if (!isBrevoConfigured()) {
    return { success: false, error: 'Brevo not configured' };
  }

  const recipients = Array.isArray(to)
    ? to.map(t => (typeof t === 'string' ? { email: t } : t))
    : [{ email: to }];

  const senderEmail = config.email.brevoSenderEmail || config.email.user;

  try {
    const response = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'api-key': config.email.brevoApiKey
      },
      body: JSON.stringify({
        sender: { name: config.email.brevoSenderName || 'ZELDA', email: senderEmail },
        to: recipients,
        subject,
        htmlContent: html
      })
    });

    if (response.status === 201 || response.status === 200) {
      console.log(`📧 Email sent to ${recipients.map(r => r.email).join(', ')} via Brevo`);
      return { success: true };
    }

    const body = await response.text();
    console.error(`Email send error: Brevo ${response.status}: ${body}`);
    return { success: false, error: `Brevo ${response.status}: ${body}` };
  } catch (error) {
    console.error('Brevo send error:', error.message);
    return { success: false, error: error.message };
  }
};

const sendEmail = async (to, subject, html) => {
  const failures = [];

  if (config.email.sendgridApiKey) {
    const sg = await sendViaSendGrid(to, subject, html);
    if (sg.success) return sg;
    failures.push(sg.error);
    console.warn(`SendGrid failed (${sg.error}); trying next provider`);
  }

  if (isBrevoConfigured()) {
    const brevo = await sendViaBrevo(to, subject, html);
    if (brevo.success) return brevo;
    failures.push(brevo.error);
    console.warn(`Brevo failed (${brevo.error}); trying next provider`);
  }

  if (isSmtpConfigured()) {
    const smtp = await sendViaSMTP(to, subject, html);
    if (smtp.success) return smtp;
    failures.push(smtp.error);
  }

  if (!failures.length) {
    console.warn('⚠️ Email not configured - cannot send');
    return { success: false, error: 'Email not configured' };
  }

  return { success: false, error: failures.join('; ') };
};

const sendOTPEmail = async (email, name, otp) => {
  return sendEmail(
    email,
    'ZELDA - Email Verification',
    `
        <div style="font-family: 'Segoe UI', Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #fafafa; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 12px rgba(0,0,0,0.08);">
          <div style="background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); padding: 30px; text-align: center;">
            <h1 style="color: #e94560; margin: 0; font-size: 28px; letter-spacing: 3px;">ZELDA</h1>
            <p style="color: #a0a0b0; margin: 5px 0 0; font-size: 13px;">Women Safety Guardian</p>
          </div>
          <div style="padding: 30px;">
            <p style="color: #333; font-size: 16px;">Hello ${name},</p>
            <p style="color: #555;">Thank you for registering. Use the OTP below to verify your email:</p>
            <div style="background: #f0f0f5; padding: 20px; text-align: center; border-radius: 8px; margin: 20px 0; border: 1px solid #e0e0e5;">
              <span style="font-size: 36px; font-weight: bold; letter-spacing: 8px; color: #e94560;">${otp}</span>
            </div>
            <p style="color: #888; font-size: 13px;">This OTP is valid for 5 minutes.</p>
            <p style="color: #888; font-size: 13px;">If you didn't request this, please ignore this email.</p>
          </div>
          <div style="background: #1a1a2e; padding: 15px; text-align: center;">
            <p style="color: #666; font-size: 11px; margin: 0;">ZELDA &mdash; Women Safety Guardian</p>
          </div>
        </div>
      `
  );
};

const sendSOSAlert = async (caseData, videoUrl, audioUrl) => {
  const mediaLinks = [];
  if (videoUrl) {
    mediaLinks.push(`<p><strong>Video:</strong> <a href="${videoUrl}">Play emergency video</a></p>`);
  }
  if (audioUrl) {
    mediaLinks.push(`<p><strong>Audio:</strong> <a href="${audioUrl}">Play emergency audio</a></p>`);
  }

  return sendEmail(
    config.email.policeEmail,
    `🚨 SOS ALERT - Emergency from ${caseData.user_email}`,
    `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h2 style="color: #dc2626;">🚨 SOS EMERGENCY ALERT</h2>
        <p><strong>User:</strong> ${caseData.user_email}</p>
        <p><strong>Status:</strong> ${caseData.status}</p>
        <p><strong>Time:</strong> ${caseData.created_at}</p>
        ${caseData.location_link ? `<p><strong>Location:</strong> <a href="${caseData.location_link}">View on Google Maps</a></p>` : ''}
        ${caseData.notes ? `<p><strong>Notes:</strong> ${caseData.notes}</p>` : ''}
        ${mediaLinks.join('')}
        <p style="color: #dc2626; font-weight: bold;">Immediate response required.</p>
      </div>
    `
  );
};

const sendContactSOSAlert = async (caseData, contact) => {
  return sendEmail(
    contact.email,
    `🚨 SOS EMERGENCY - ${caseData.user_email} needs help!`,
    `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h2 style="color: #dc2626;">🚨 SOS EMERGENCY ALERT</h2>
        <p>Hello <strong>${contact.name}</strong>,</p>
        <p><strong>${caseData.user_email}</strong> has triggered an emergency SOS alert.</p>
        ${caseData.location_link ? `<p><strong>Location:</strong> <a href="${caseData.location_link}">View on Google Maps</a></p>` : ''}
        ${caseData.notes ? `<p><strong>Details:</strong> ${caseData.notes}</p>` : ''}
        <p><strong>Time:</strong> ${caseData.created_at}</p>
        <hr>
        <p style="color: #dc2626; font-weight: bold;">Please check on them immediately.</p>
      </div>
    `
  );
};

const sendTestEmail = async () => {
  return sendEmail(
    config.email.policeEmail,
    'Test Email - Women Safety Guardian',
    '<p>This is a test email from Women Safety Guardian.</p>'
  );
};

module.exports = { sendOTPEmail, sendSOSAlert, sendContactSOSAlert, sendTestEmail, isEmailConfigured };