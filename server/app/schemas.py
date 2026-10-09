from datetime import datetime
from pydantic import AliasChoices, BaseModel, EmailStr, Field, field_validator


class RegisterRequest(BaseModel):
    phone: str = Field(min_length=7, max_length=32, pattern=r"^[+0-9(). -]+$")
    email: EmailStr
    password: str = Field(min_length=12, max_length=128)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class VerifyRequest(BaseModel):
    token: str = Field(min_length=32, max_length=128)


class VerifyRequestEmail(BaseModel):
    email: EmailStr


class EnteredRequest(BaseModel):
    note: str | None = Field(default=None, max_length=2000)


class SettingsRequest(BaseModel):
    emailNotifications: bool
    pushNotifications: bool
    fcmToken: str | None = Field(default=None, max_length=512)


class AdminSettingsRequest(BaseModel):
    minSignalScore: int = Field(ge=65, le=100, validation_alias=AliasChoices("minSignalScore", "minimumSignalScore"))
    activeExchanges: list[str] = Field(
        min_length=1, validation_alias=AliasChoices("activeExchanges", "exchanges")
    )

    @field_validator("activeExchanges")
    @classmethod
    def validate_exchanges(cls, exchanges: list[str]) -> list[str]:
        allowed = {"binance", "bybit", "okx"}
        if any(exchange not in allowed for exchange in exchanges):
            raise ValueError("activeExchanges may contain only binance, bybit, okx")
        if len(set(exchanges)) != len(exchanges):
            raise ValueError("activeExchanges cannot contain duplicates")
        return exchanges


class SubscriptionRequest(BaseModel):
    months: int = Field(ge=1, le=24)


class SubscriptionResponse(BaseModel):
    email: str
    startsAt: datetime
    expiresAt: datetime
