"""Settings for every Mobile Lab Station service.

Values come from the environment first, then from the repository .env file.
systemd supplies the environment through EnvironmentFile. A person running a
service by hand gets the same values from .env.
"""

from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[2]
ENV_FILE = REPO_ROOT / ".env"


def _readable_env_file() -> Path | None:
    """Return the .env path only if this process can read it.

    systemd already supplies the environment through EnvironmentFile. A service
    user that cannot read .env must still start, so an unreadable file is not an
    error here.
    """
    try:
        with ENV_FILE.open("r", encoding="utf-8"):
            return ENV_FILE
    except OSError:
        return None


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=_readable_env_file(),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    mobilelab_db: str = "mobilelab"
    mobilelab_db_user: str = "mobilelab"
    mobilelab_db_password: str = ""
    mobilelab_db_host: str = "127.0.0.1"
    mobilelab_db_port: int = 5432

    mobilelab_station_id: str = "lab01"
    mobilelab_station_label: str = "Mobile Lab Station"

    mobilelab_mqtt_host: str = "127.0.0.1"
    mobilelab_mqtt_port: int = 1883
    mobilelab_mqtt_topic: str = "station/#"

    mobilelab_writer_queue_size: int = 10000
    mobilelab_writer_report_seconds: int = 300

    # The API binds to every interface on purpose. The kiosk browser and a
    # teacher laptop both have to reach it. There is no authentication yet.
    # See the README, "Local API", for the dev cycle note on this.
    mobilelab_api_host: str = "0.0.0.0"
    mobilelab_api_port: int = 8000

    # The bridge listens where the WQL loggers can reach it. When hostapd runs
    # on wlan0 the loggers join that network and POST here.
    mobilelab_bridge_host: str = "0.0.0.0"
    mobilelab_bridge_port: int = 8081

    def dsn(self) -> str:
        return (
            f"host={self.mobilelab_db_host} "
            f"port={self.mobilelab_db_port} "
            f"dbname={self.mobilelab_db} "
            f"user={self.mobilelab_db_user} "
            f"password={self.mobilelab_db_password}"
        )


def load_settings() -> Settings:
    return Settings()
