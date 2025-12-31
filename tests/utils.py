import json
import os
import uuid

TEST_SESSION_ID = str(uuid.uuid4())[:8]


def get_test_identifier(test_name: str) -> str:
    """Generate a unique identifier for test data."""
    return f"{test_name}_{TEST_SESSION_ID}_{uuid.uuid4().hex[:8]}"


def _db_dsn(db_name: str | None = None) -> str:
    db_host = os.getenv("POSTGRES_HOST", "localhost")
    db_port = os.getenv("POSTGRES_PORT", "43815")
    db_name = db_name or os.getenv("POSTGRES_DB", "hexis_memory")
    db_user = os.getenv("POSTGRES_USER", "hexis_user")
    db_password = os.getenv("POSTGRES_PASSWORD", "hexis_password")
    return f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"


def _coerce_json(val):
    if isinstance(val, str):
        return json.loads(val)
    return val


async def _set_embedding_retry_config(
    conn,
    retry_seconds: int,
    retry_interval_seconds: float,
):
    original_retry_seconds = await conn.fetchval(
        "SELECT value FROM embedding_config WHERE key = 'retry_seconds'"
    )
    original_retry_interval_seconds = await conn.fetchval(
        "SELECT value FROM embedding_config WHERE key = 'retry_interval_seconds'"
    )
    await conn.execute(
        """
        INSERT INTO embedding_config (key, value)
        VALUES ('retry_seconds', $1)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
        """,
        str(retry_seconds),
    )
    await conn.execute(
        """
        INSERT INTO embedding_config (key, value)
        VALUES ('retry_interval_seconds', $1)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
        """,
        str(retry_interval_seconds),
    )
    return original_retry_seconds, original_retry_interval_seconds


async def _restore_embedding_retry_config(
    conn,
    original_retry_seconds,
    original_retry_interval_seconds,
):
    if original_retry_seconds is None:
        await conn.execute("DELETE FROM embedding_config WHERE key = 'retry_seconds'")
    else:
        await conn.execute(
            "UPDATE embedding_config SET value = $1 WHERE key = 'retry_seconds'",
            original_retry_seconds,
        )
    if original_retry_interval_seconds is None:
        await conn.execute(
            "DELETE FROM embedding_config WHERE key = 'retry_interval_seconds'"
        )
    else:
        await conn.execute(
            "UPDATE embedding_config SET value = $1 WHERE key = 'retry_interval_seconds'",
            original_retry_interval_seconds,
        )
