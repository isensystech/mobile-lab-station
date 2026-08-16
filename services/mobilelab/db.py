"""The database layer.

The connection uses autocommit. Each insert is then its own transaction, so one
rejected row cannot poison the next one.

Two failures are different and the caller must tell them apart:

  DataRejected         the database refused this row. The row is bad.
  DatabaseUnavailable  the database did not answer. The row may be good.
"""

from __future__ import annotations

import json
import logging

import psycopg
from psycopg import errors as pg_errors

from .record import Reading

log = logging.getLogger(__name__)

INSERT_SQL = """
insert into public.readings
  (station_id, sensor, metric, value, unit, ts, lat, lon, source,
   observation_id, value_raw, unit_raw, ref_distance_m, quality_flag, provenance)
values
  (%(station_id)s, %(sensor)s, %(metric)s, %(value)s, %(unit)s, %(ts)s,
   %(lat)s, %(lon)s, %(source)s, %(observation_id)s, %(value_raw)s,
   %(unit_raw)s, %(ref_distance_m)s, %(quality_flag)s, %(provenance)s)
returning id
"""


class DataRejected(Exception):
    """The database refused the row. The row is at fault."""

    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(f"{reason}: {detail}")
        self.reason = reason
        self.detail = detail


class DatabaseUnavailable(Exception):
    """The database did not answer. The row is not at fault."""


class Database:
    def __init__(self, dsn: str, connect_timeout: int = 5) -> None:
        self._dsn = f"{dsn} connect_timeout={connect_timeout}"
        self._conn: psycopg.Connection | None = None

    def connect(self) -> psycopg.Connection:
        if self._conn is not None and not self._conn.closed:
            return self._conn
        try:
            self._conn = psycopg.connect(self._dsn, autocommit=True)
        except psycopg.OperationalError as exc:
            self._conn = None
            raise DatabaseUnavailable(str(exc).strip()) from exc
        log.info("connected to the database")
        return self._conn

    def close(self) -> None:
        if self._conn is not None and not self._conn.closed:
            self._conn.close()
        self._conn = None

    def insert_reading(self, reading: Reading) -> int:
        """Insert one row. Return the new id."""
        params = reading.model_dump()
        params["provenance"] = (
            json.dumps(params["provenance"]) if params["provenance"] is not None else None
        )
        params["observation_id"] = (
            str(params["observation_id"]) if params["observation_id"] is not None else None
        )

        for attempt in (1, 2):
            conn = self.connect()
            try:
                with conn.cursor() as cur:
                    cur.execute(INSERT_SQL, params)
                    row = cur.fetchone()
                    return int(row[0])
            except pg_errors.ForeignKeyViolation as exc:
                raise DataRejected("foreign_key", _first_line(exc)) from exc
            except pg_errors.CheckViolation as exc:
                raise DataRejected("check_constraint", _first_line(exc)) from exc
            except pg_errors.NotNullViolation as exc:
                raise DataRejected("not_null", _first_line(exc)) from exc
            except pg_errors.DataError as exc:
                raise DataRejected("bad_data", _first_line(exc)) from exc
            except psycopg.OperationalError as exc:
                self.close()
                if attempt == 2:
                    raise DatabaseUnavailable(str(exc).strip()) from exc
                log.warning("the database connection dropped, reconnecting")

        raise DatabaseUnavailable("the insert did not complete")

    def source_is_real(self, source: str) -> bool | None:
        """Return is_real for a source. Return None if the source is unknown."""
        conn = self.connect()
        with conn.cursor() as cur:
            cur.execute("select is_real from public.sources where source = %s", (source,))
            row = cur.fetchone()
        if row is None:
            return None
        return bool(row[0])


def _first_line(exc: Exception) -> str:
    return str(exc).strip().splitlines()[0]
