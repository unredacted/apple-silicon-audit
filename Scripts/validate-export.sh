#!/bin/zsh
# Validate one or more export JSON files against Schema/export-v1.schema.json (JSON Schema 2020-12).
# Usage: Scripts/validate-export.sh file.json [more.json...]
# Needs node; uses npx to fetch ajv-cli and ajv-formats on first run.
set -euo pipefail
cd "$(dirname "$0")/.."
rc=0
for f in "$@"; do
  if npx --yes -p ajv-cli@5 -p ajv-formats@2 ajv validate --spec=draft2020 -c ajv-formats --errors=text -s Schema/export-v1.schema.json -d "$f" 2>&1 | grep -vE '^npm|^$|strict mode' | grep -q ' valid$'; then
    echo "valid    $f"
  else
    echo "INVALID  $f"; npx --yes -p ajv-cli@5 -p ajv-formats@2 ajv validate --spec=draft2020 -c ajv-formats --errors=text -s Schema/export-v1.schema.json -d "$f" 2>&1 | grep -vE '^npm|^$|strict mode' | tail -5; rc=1
  fi
done
exit $rc
