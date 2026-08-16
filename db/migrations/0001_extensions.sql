-- migrate:no-transaction
--
-- 0001 extensions
--
-- TimescaleDB must load before it creates objects. The loader library comes from
-- shared_preload_libraries. See ops/install-timescaledb.sh.
--
-- This file runs outside a transaction. CREATE EXTENSION timescaledb refuses to
-- run inside a transaction block that already holds other work.

create extension if not exists timescaledb;
