#!/bin/bash
 
# Server's addrres
BASE_URL=""
# Admin user Bearer token from login session
BEARER_TOKEN=""
# Service token from Administration -> Service Accounts
SERVICE_TOKEN=""
 
GEO_ZONE_URL="${BASE_URL}/api/geographicZones"
LOCATION_URL="${BASE_URL}/hapifhir/Location"

# Logic
function refresh_geographic_zones() {
    # Initialize an empty array to store items
    items=()

    # Fetch and store the items in the array
    while IFS= read -r item; do
        items+=("$item")
    done < <(curl --silent -X GET "${1}" -H "Authorization: Bearer ${BEARER_TOKEN}" | jq -c '.content[]')

    # Initialize an array to store items with 'levelNumber' prefixes for sorting
    sorted_items=()
    
    # Iterate through each item and extract 'levelNumber' for sorting
    for item in "${items[@]}"; do
        # Extract the 'levelNumber' field from the current item
        levelNumber=$(jq -r '.level.levelNumber' <<< "$item")
        
         # Append the item to the sorted_items array with 'levelNumber' as a prefix
        sorted_items+=("$levelNumber|$item")
    done

    # Set the Internal Field Separator (IFS) to newline and sort the items based on 'levelNumber'
    IFS=$'\n' sorted_items=($(sort -t'|' -k1,1n <<<"${sorted_items[*]}"))
    unset IFS

    # Print the count of sorted items
    echo "Number of items to refresh: ${#sorted_items[@]}"

    # Iterate through the sorted items
    for sorted_item in "${sorted_items[@]}"; do
        # Extract the original item
        item=${sorted_item#*|}

        # Process each sorted item
        ID=$(jq -r '.id' <<< "$item")
        echo -n "Processing ${2} with ID: $ID"

        STATUS=$(curl --write-out "%{http_code}\n" --silent --output /dev/null -X PUT "${1}/${ID}" -H "Authorization: Bearer ${BEARER_TOKEN}" -H "Content-Type: application/json" -d "$item")

        if [ "$STATUS" == "200" ]; then
            echo " - OK"
        else
            echo " - FAIL ($STATUS)"
        fi

        TOTAL=$(curl --silent -X GET "${LOCATION_URL}?identifier=${BASE_URL}%7C${ID}" -H "Authorization: Bearer ${SERVICE_TOKEN}" | jq -r ".total")

        if [ "$TOTAL" == "0" ]; then
            echo "Hapifhir check - FAIL"
        else
            echo "Hapifhir check - OK"
        fi
    done
}

refresh_geographic_zones ${GEO_ZONE_URL} "geographic zone"
