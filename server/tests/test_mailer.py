from app.config import Settings
from app.mailer import send_verification_email


def test_verification_email_uses_brevo_http_api(monkeypatch):
    captured = {}

    class Response:
        def raise_for_status(self):
            captured["raised"] = True

    def post(url, *, headers, json, timeout):
        captured.update(url=url, headers=headers, json=json, timeout=timeout)
        return Response()

    monkeypatch.setattr("app.mailer.httpx.post", post)
    settings = Settings(
        jwt_secret="test-secret-that-is-long-enough-for-validation",
        brevo_api_key="test-api-key",
        smtp_from="verified@example.test",
    )

    assert send_verification_email("user@example.test", "single-use-token", settings)
    assert captured["url"] == "https://api.brevo.com/v3/smtp/email"
    assert captured["headers"]["api-key"] == "test-api-key"
    assert captured["json"]["to"] == [{"email": "user@example.test"}]
    assert "single-use-token" in captured["json"]["textContent"]
    assert captured["raised"]


def test_verification_email_reports_missing_delivery_configuration():
    settings = Settings(
        jwt_secret="test-secret-that-is-long-enough-for-validation",
    )

    assert not send_verification_email("user@example.test", "token", settings)
