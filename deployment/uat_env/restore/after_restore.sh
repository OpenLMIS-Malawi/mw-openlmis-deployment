#!/bin/bash

: ${DATABASE_URL:?"Need to set DATABASE_URL"}
: ${POSTGRES_USER:?"Need to set POSTGRES_USER"}
: ${POSTGRES_PASSWORD:?"Need to set POSTGRES_PASSWORD"}

: ${ENCODED_USER_PASSWORD:?"Need to set ENCODED_USER_PASSWORD"}
: ${CLIENT_USERNAME:?"Need to set CLIENT_USERNAME"}
: ${CLIENT_SECRET:?"Need to set CLIENT_SECRET"}
: ${SERVICE_CLIENT_SECRET:?"Need to set SERVICE_CLIENT_SECRET"}
: ${CLIENT_REDIRECT_URI:?"Need to set CLIENT_REDIRECT_URI"}

URL=`echo ${DATABASE_URL} | sed -E 's/^jdbc\:(.+)/\1/'` # jdbc:<url>
: "${URL:?URL not parsed}"

sql=$(cat <<EOF
UPDATE auth.auth_users SET password = '${ENCODED_USER_PASSWORD}';
UPDATE notification.user_contact_details SET email = NULL;
UPDATE auth.oauth_client_details SET clientid = 'uat-service-client', clientsecret = '${SERVICE_CLIENT_SECRET}' WHERE clientid = 'production-service-client';
UPDATE auth.oauth_client_details SET clientsecret = '${CLIENT_SECRET}' WHERE clientid = 'malawi-client';
UPDATE auth.oauth_client_details SET clientid = '${CLIENT_USERNAME}' WHERE clientid = 'malawi-client';
UPDATE auth.oauth_client_details SET redirecturi = '${CLIENT_REDIRECT_URI}' WHERE clientid = 'superset';
EOF
)

PGPASSWORD="${POSTGRES_PASSWORD}" psql ${URL} -U ${POSTGRES_USER} -c "$sql"
