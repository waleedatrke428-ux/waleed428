import smtplib
from email.message import EmailMessage

import httpx

from app.config import Settings


def send_verification_email(email: str, token: str, settings: Settings) -> bool:
    if not settings.smtp_from:
        return False

    subject = "Verify your Crypto Albalhousi account"
    content = (
        f"Verify your email using this one-time token in the app: {token}\n"
        "Token expires in 24 hours. Do not share it."
    )
    if settings.brevo_api_key:
        response = httpx.post(
            "https://api.brevo.com/v3/smtp/email",
            headers={"accept": "application/json", "api-key": settings.brevo_api_key},
            json={
                "sender": {"name": "Crypto Albalhousi", "email": settings.smtp_from},
                "to": [{"email": email}],
                "subject": subject,
                "textContent": content,
            },
            timeout=10,
        )
        response.raise_for_status()
        return True

    if not settings.smtp_host:
        return False
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = settings.smtp_from
    message["To"] = email
    message.set_content(content)
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as smtp:
        if settings.smtp_starttls:
            smtp.starttls()
        if settings.smtp_username:
            smtp.login(settings.smtp_username, settings.smtp_password)
        smtp.send_message(message)
    return True
