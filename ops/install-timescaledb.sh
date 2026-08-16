#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

PG_MAJOR="${PG_MAJOR:-17}"
KEYRING="/usr/share/keyrings/timescale-archive-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/timescaledb.sources"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

echo "==> Debian codename ${CODENAME}, PostgreSQL major ${PG_MAJOR}"

echo "==> The Debian package postgresql-${PG_MAJOR}-timescaledb is the Apache edition."
echo "    It has no continuous aggregates. Arch section 2 requires them."
echo "    This script installs the community edition from Timescale instead."

if dpkg -l "postgresql-${PG_MAJOR}-timescaledb" 2> /dev/null | grep -q '^ii'; then
  echo "==> removing the Debian Apache edition"
  apt-get remove -y "postgresql-${PG_MAJOR}-timescaledb"
fi

echo "==> installing prerequisites"
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates "postgresql-${PG_MAJOR}"

echo "==> adding the Timescale packagecloud repository"
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
  | gpg --dearmor --yes -o "${KEYRING}"
chmod 0644 "${KEYRING}"

cat > "${SOURCES}" <<EOF
Types: deb
URIs: https://packagecloud.io/timescale/timescaledb/debian/
Suites: ${CODENAME}
Components: main
Signed-By: ${KEYRING}
EOF

apt-get update -qq

echo "==> installing the TimescaleDB community edition"
apt-get install -y -qq \
  "timescaledb-2-postgresql-${PG_MAJOR}" \
  timescaledb-tools

echo "==> installed versions"
dpkg-query -W -f='${Package} ${Version}\n' \
  "timescaledb-2-postgresql-${PG_MAJOR}" \
  "timescaledb-2-loader-postgresql-${PG_MAJOR}" \
  timescaledb-tools \
  "postgresql-${PG_MAJOR}"

CONF="/etc/postgresql/${PG_MAJOR}/main/postgresql.conf"

if command -v timescaledb-tune > /dev/null 2>&1; then
  echo "==> running timescaledb-tune against ${CONF}"
  timescaledb-tune \
    --quiet --yes \
    --conf-path="${CONF}" \
    --pg-config="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"
  echo "==> timescaledb-tune finished"
else
  echo "==> timescaledb-tune is absent, setting shared_preload_libraries by hand"
  if grep -qE "^[[:space:]]*shared_preload_libraries" "${CONF}"; then
    sed -i "s|^[[:space:]]*shared_preload_libraries.*|shared_preload_libraries = 'timescaledb'|" "${CONF}"
  else
    echo "shared_preload_libraries = 'timescaledb'" >> "${CONF}"
  fi
fi

echo "==> restarting PostgreSQL"
systemctl enable postgresql
systemctl restart "postgresql@${PG_MAJOR}-main"
systemctl restart postgresql

echo "==> data directory"
runuser -u postgres -- psql -t -A -c "show data_directory"

echo "==> done"
