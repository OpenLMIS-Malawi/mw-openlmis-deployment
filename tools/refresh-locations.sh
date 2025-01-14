#!/bin/bash
 
# Server's addrres
BASE_URL=""
# Admin user Bearer token from login session
BEARER_TOKEN=""
# Service token from Administration -> Service Accounts
SERVICE_TOKEN=""
 
GEO_ZONE_URL="${BASE_URL}/api/geographicZones"
FACILITY_URL="${BASE_URL}/api/facilities"
LOCATION_URL="${BASE_URL}/hapifhir/Location"
 
 
# logic
function refresh_resources() {
    curl --silent -X GET "${1}" -H "Authorization: Bearer ${BEARER_TOKEN}" | jq -c '.content[]' | while read item; do
        ID=`echo ${item} | jq -r '.id'`
 
        echo -n $2
        echo -n "  ${ID}"
 
        STATUS=`curl --write-out "%{http_code}\n" --silent --output /dev/null -X PUT "${1}/${ID}" -H "Authorization: Bearer ${BEARER_TOKEN}" -H "Content-Type: application/json" -d "${item}"`
         
        if [ "${STATUS}" == "200" ]; then
            echo -n "  OK        "
        else
            echo -n "  FAIL (${STATUS})"
        fi
         
        TOTAL=`curl --silent -X GET "${LOCATION_URL}?identifier=${BASE_URL}%7C${ID}" -H "Authorization: Bearer ${SERVICE_TOKEN}" | jq -r ".total"`
 
        if [ "${TOTAL}" == "0" ]; then
            echo "  FAIL"
        else
            echo "  OK"
        fi
    done
}
 
refresh_resources ${GEO_ZONE_URL} "geographic zone"
refresh_resources ${FACILITY_URL} "facility"
