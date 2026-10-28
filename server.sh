#!/bin/bash
generate_assignment_json() {
    local section title topic due_date points

    if ! curl -fLsS -o /tmp/info1112.html \
        "https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"; then
        echo "Error: Cannot download webpage"
        return 1
    fi

    if ! html2text -width 200 /tmp/info1112.html > /tmp/info1112.txt; then
        echo "Error: Cannot convert HTML"
        return 1
    fi

    section=$(grep -A 2 "Assignment 2" /tmp/info1112.txt)

    title=$(printf '%s\n' "$section" | grep -oE 'Assignment[[:space:]]+[0-9]+' | head -n 1)

    topic=$(printf '%s\n' "$section" | sed -nE 's/.*Programming task - ([A-Za-z]+).*/\1/p' | head -n 1)

    due_date=$(printf '%s\n' "$section" | grep -oE 'Due date: [0-9]{2} [A-Za-z]{3} [0-9]{4} at [0-9]{2}:[0-9]{2}' | sed 's/Due date: //; s/ at / /')

    points=$(printf '%s\n' "$section" | grep -oE '[0-9]+%' | head -n 1 | tr -d '%')

    if [ -z "$title" ] || [ -z "$topic" ] || [ -z "$due_date" ] || [ -z "$points" ]; then
        echo "Error: Missing assignment information"
        return 1
    fi

    jq -n \
        --arg title "$title" \
        --arg topic "$topic" \
        --arg due_date "$due_date" \
        --argjson points "$points" \
        '{title:$title, topic:$topic, due_date:$due_date, points:$points}' \
        > /root/assignment.json
}
server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

generate_population_png() {
    local csv_file="/tmp/STE_1.csv"
    local data_file="/tmp/nsw_population_years.csv"
    local output_file="/root/population.png"

    if ! curl -fLsS -o "$csv_file" \
        "https://dbr.abs.gov.au/processedData/csv/STE_1.csv"; then
        echo "Error: Cannot download population CSV"
        return 1
    fi

    awk -F',' '
    NR==1 {
        for(i=4;i<=NF;i++) {
            gsub(/\r/,"",$i)
            year[i]=$i
        }
    }
    $1=="ERP_P_20" {
        for(i=4;i<=NF;i++) {
            gsub(/\r/,"",$i)
            if(year[i] ~ /^[0-9][0-9][0-9][0-9]$/ && $i ~ /^[0-9]+$/)
                print year[i] "," $i
        }
    }' "$csv_file" > "$data_file"

    local population
    population=$(awk -F',' '$1=="2025" {print $2}' "$data_file")

    if [ -z "$population" ]; then
        echo "Error: Cannot find 2025 NSW population"
        return 1
    fi

    echo "NSW Population 2025: $population"

    if ! python3 /root/plot_population.py "$data_file" "$output_file"; then
        echo "Error: Cannot generate population plot"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        echo "Error: Population image is missing"
        return 1
    fi
}


generate_poi_json() {
    local latitude="$1"
    local longitude="$2"
    local query

    # Check coordinates
    if ! [[ "$latitude" =~ ^-?[0-9]+(\.[0-9]+)?$ &&
            "$longitude" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: Invalid coordinates"
        return 1
    fi

    if ! awk -v lat="$latitude" -v lon="$longitude" \
        'BEGIN {exit !(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)}'; then
        echo "Error: Coordinates out of range"
        return 1
    fi

    # Find POIs within 500 metres
    query="[out:json][timeout:10];node(around:500,${latitude},${longitude})[name];out 20;"
    if ! curl -fLsS --max-time 45 \
        -A "INFO1112-A2-POI-Demo/1.0" \
        --data-urlencode "data=$query" \
        -o /tmp/poi_raw.json \
        "https://overpass.openstreetmap.fr/api/interpreter"; then
        echo "Error: Cannot download POI data"
        return 1
    fi

    # Convert data into a JSON list
    if ! jq -e '
        if (.elements | type) != "array" then
            error("Missing POI data")
        else
            [.elements[] |
                select(.tags.name != null) |
                {
                    name: .tags.name,
                    latitude: (.lat // .center.lat),
                    longitude: (.lon // .center.lon),
                    type: .type
                }
            ]
        end
    ' /tmp/poi_raw.json > /root/poi.json; then
        echo "Error: Cannot generate POI JSON"
        return 1
    fi

    echo "POI JSON generated successfully"
}


resolve_place_coordinates() {
    local place="$1"
    local coords

    if ! curl -fLsS --connect-timeout 8 --max-time 20 -G \
        -A "INFO1112-A2-Student/1.0 (https://github.com/abc3381852217-jpg/INFO1112-A2)" \
        --data-urlencode "q=$place" \
        --data-urlencode "format=jsonv2" \
        --data-urlencode "limit=1" \
        -o /tmp/place_search.json \
        "https://nominatim.openstreetmap.org/search"; then
        echo "Error: Cannot search place name" >&2
        return 1
    fi

    coords=$(jq -er '.[0] | select(.lat != null and .lon != null) | "\(.lat) \(.lon)"' /tmp/place_search.json) || {
        echo "Error: Place not found" >&2
        return 1
    }

    echo "$coords"
}

if [ -z "$server_ip" ]; then
    echo "Error: Cannot find server IP"
    exit 1
fi

echo "The server is running at Link addr:$server_ip"

while true
do
    echo "Waiting for client..."

    coproc CLIENT { nc -N -v -l 1234; }

    if IFS= read -r request <&"${CLIENT[0]}"; then
        echo "Received request: $request"

        
if [ "$request" = "assignment" ]; then
    echo "Processing assignment request..."

    if generate_assignment_json; then
        cat /root/assignment.json >&"${CLIENT[1]}"
    else
        echo "Error: Failed to generate assignment JSON" >&"${CLIENT[1]}"
    fi

elif [ "$request" = "population" ]; then
    echo "Processing population request..."

    if generate_population_png; then
        cat /root/population.png >&"${CLIENT[1]}"
    else
        echo "Error: Failed to generate population PNG" >&"${CLIENT[1]}"
    fi



elif [[ "$request" == poi\ * ]]; then
    echo "Processing POI request..."

    read -r command arg1 arg2 extra <<< "$request"

    latitude=""
    longitude=""

    if [ -z "$arg1" ]; then
        echo "Error: Use poi latitude longitude or poi place name" >&"${CLIENT[1]}"

    elif [[ "$arg1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        if [[ "$arg2" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && [ -z "$extra" ]; then
            latitude="$arg1"
            longitude="$arg2"
        else
            echo "Error: Use poi latitude longitude" >&"${CLIENT[1]}"
        fi

    else
        place="${request#poi }"

        if coords=$(resolve_place_coordinates "$place"); then
            read -r latitude longitude <<< "$coords"
        else
            echo "Error: Place not found" >&"${CLIENT[1]}"
        fi
    fi

    if [ -n "$latitude" ] && [ -n "$longitude" ]; then
        if generate_poi_json "$latitude" "$longitude"; then
            cat /root/poi.json >&"${CLIENT[1]}"
        else
            echo "Error: Failed to generate POI JSON" >&"${CLIENT[1]}"
        fi
    fi

else
    echo "Error: Unknown request" >&"${CLIENT[1]}"
fi

    fi

    exec {CLIENT[1]}>&-
    wait "$CLIENT_PID"
done