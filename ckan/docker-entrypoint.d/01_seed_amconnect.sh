#!/bin/bash
# Seed the AMConnect example organisation + dataset (idempotent).
if [ "${AMCONNECT_SEED:-true}" = "true" ]; then
  echo "[amconnect] seeding example dataset"
  ckan -c "$CKAN_INI" amconnect seed || echo "[amconnect] seeding FAILED (CKAN will still start)"
fi
