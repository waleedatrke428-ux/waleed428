import smtplib
from email.message import EmailMessage

from app.config import Settings


def send_verification_email(email: str, token: str, settings: Settings) -> bool:
    if not (settings.smtp_host and settings.smtp_from):
        return False
    message = EmailMessage()
    message["Subject"] = "Verify your signal-platform account"
    message["From"] = settings.smtp_from
    message["To"] = email
    message.set_content(
        f"Verify your email using this one-time token in the app: {token}\n"
        f"Token expires in 24 hours. Do not share it."
    )
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as smtp:
        if settings.smtp_starttls:
            smtp.starttls()
        if settings.smtp_username:
            smtp.login(settings.smtp_username, settings.smtp_password)
        smtp.send_message(message)
    return True
