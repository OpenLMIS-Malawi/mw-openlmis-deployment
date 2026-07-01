#!/bin/bash

: ${DB_HOST:?"Need to set DB_HOST"}
: ${DB_PORT:?"Need to set DB_PORT"}
: ${DB_NAME:?"Need to set DB_NAME"}
: ${POSTGRES_USER:?"Need to set POSTGRES_USER"}
: ${POSTGRES_PASSWORD:?"Need to set POSTGRES_PASSWORD"}
: ${ENCODED_USER_PASSWORD:?"Need to set ENCODED_USER_PASSWORD"}
: ${CLIENT_USERNAME:?"Need to set CLIENT_USERNAME"}
: ${CLIENT_SECRET:?"Need to set CLIENT_SECRET"}
: ${SERVICE_CLIENT_ID:?"Need to set SERVICE_CLIENT_ID"}
: ${SERVICE_CLIENT_SECRET:?"Need to set SERVICE_CLIENT_SECRET"}
: ${SUPERSET_SECRET:?"Need to set SUPERSET_SECRET"}
: ${CLIENT_REDIRECT_URI:?"Need to set CLIENT_REDIRECT_URI"}

sql=$(cat <<EOF
UPDATE auth.auth_users SET password = '${ENCODED_USER_PASSWORD}';
UPDATE notification.user_contact_details SET email = NULL, phonenumber = NULL,  allownotify = false;
UPDATE auth.oauth_client_details SET clientid = '${SERVICE_CLIENT_ID}', clientsecret = '${SERVICE_CLIENT_SECRET}' WHERE clientid = 'production-service-client';
UPDATE auth.oauth_client_details SET clientsecret = '${CLIENT_SECRET}' WHERE clientid = 'malawi-client';
UPDATE auth.oauth_client_details SET clientid = '${CLIENT_USERNAME}' WHERE clientid = 'malawi-client';
UPDATE auth.oauth_client_details SET clientsecret = '${SUPERSET_SECRET}' WHERE clientid = 'superset';
UPDATE auth.oauth_client_details SET redirecturi = '${CLIENT_REDIRECT_URI}' WHERE clientid = 'superset';
EOF
)

echo "Connecting to Host: ${DB_HOST}, Port: ${DB_PORT}, DB: ${DB_NAME} as ${POSTGRES_USER}"
echo "Executing clearing sensitive data..."

PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -U "${POSTGRES_USER}" \
    -c "$sql"

echo "Success: Sensitive data cleared."

# Reporting-stack CDC bootstrap: the snapshot restore drops the publication and
# the signal/heartbeat tables, so re-apply them before `make setup` runs (else
# the connector-registration preflight aborts). Idempotent; mirrors Step 1d in
# reporting-stack-setup.md. Keep the table list in sync with that doc and with
# SOURCE_PG_TABLE_ALLOWLIST in malawi-configuration/.env.reporting-stack.
cdc_sql=$(cat <<'EOF'
-- Heartbeat: prevents WAL accumulation during idle periods.
CREATE TABLE IF NOT EXISTS public.reporting_heartbeat (
  id INT PRIMARY KEY DEFAULT 1,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.reporting_heartbeat (id, ts) VALUES (1, NOW())
  ON CONFLICT (id) DO NOTHING;

-- Signal table: triggers Debezium incremental snapshots (make snapshot-tables).
CREATE TABLE IF NOT EXISTS public.debezium_signal (
  id   VARCHAR(42)  PRIMARY KEY,
  type VARCHAR(32)  NOT NULL,
  data VARCHAR(2048)
);

-- Publication: create if absent (first run on a freshly restored DB).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'dbz_publication') THEN
    CREATE PUBLICATION dbz_publication FOR TABLE
      public.debezium_signal,
      referencedata.facilities,
      referencedata.programs,
      referencedata.geographic_zones,
      referencedata.orderables,
      referencedata.processing_periods,
      referencedata.processing_schedules,
      referencedata.facility_types,
      referencedata.supported_programs,
      referencedata.requisition_group_members,
      referencedata.requisition_group_program_schedules,
      requisition.requisitions,
      requisition.requisition_line_items,
      requisition.status_changes,
      requisition.stock_adjustments,
      requisition.stock_adjustment_reasons;
  END IF;
END $$;

-- Always re-set the table list: idempotent when correct, and repairs the
-- publication if a table was dropped/recreated (Flyway silently removes
-- recreated tables from publications).
ALTER PUBLICATION dbz_publication SET TABLE
  public.debezium_signal,
  referencedata.facilities,
  referencedata.programs,
  referencedata.geographic_zones,
  referencedata.orderables,
  referencedata.processing_periods,
  referencedata.processing_schedules,
  referencedata.facility_types,
  referencedata.supported_programs,
  referencedata.requisition_group_members,
  referencedata.requisition_group_program_schedules,
  requisition.requisitions,
  requisition.requisition_line_items,
  requisition.status_changes,
  requisition.stock_adjustments,
  requisition.stock_adjustment_reasons;
EOF
)

echo "Re-applying reporting-stack CDC objects (publication + signal/heartbeat)..."

if PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -U "${POSTGRES_USER}" \
    -c "$cdc_sql"; then
  echo "Success: reporting-stack CDC objects in place."
else
  echo "ERROR: failed to apply reporting-stack CDC objects — the reporting-stack" >&2
  echo "connector preflight will abort until the publication/signal tables exist." >&2
  exit 1
fi
