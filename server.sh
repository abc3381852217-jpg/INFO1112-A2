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
    query="[out:json][timeout:25];nwr(around:500,${latitude},${longitude})[name];out center;"
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


handle_client() {
    local ip="${SOCAT_PEERADDR:-unknown}"
    local safe_ip="${ip//[^a-zA-Z0-9]/_}"
    local lock="/tmp/info1112_${safe_ip}.lock"
    local request

    if ! mkdir "$lock" 2>/dev/null; then
        echo "Error: Client already connected"
        return 0
    fi

    trap "rmdir '$lock' 2>/dev/null" EXIT

    if ! IFS= read -r request; then
        return 0
    fi

    echo "Client IP: $ip" >&2
    echo "Received request: $request" >&2

    if [ "$request" = "assignment" ]; then
        echo "Processing assignment request..." >&2

        if generate_assignment_json >&2; then
            cat /root/assignment.json
        else
            echo "Error: Failed to generate assignment JSON"
        fi

    elif [ "$request" = "population" ]; then
        echo "Processing population request..." >&2

        if generate_population_png >&2; then
            cat /root/population.png
        else
            echo "Error: Failed to generate population PNG"
        fi

    elif [[ "$request" == poi\ * ]]; then
        echo "Processing POI request..." >&2

        local command arg1 arg2 extra
        local latitude="" longitude="" place coords

        read -r command arg1 arg2 extra <<< "$request"

        if [ -z "$arg1" ]; then
            echo "Error: Use poi latitude longitude or poi place name"

        elif [[ "$arg1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            if [[ "$arg2" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && [ -z "$extra" ]; then
                latitude="$arg1"
                longitude="$arg2"
            else
                echo "Error: Use poi latitude longitude"
            fi

        else
            place="${request#poi }"

            if coords=$(resolve_place_coordinates "$place"); then
                read -r latitude longitude <<< "$coords"
            else
                echo "Error: Place not found"
            fi
        fi

        if [ -n "$latitude" ] && [ -n "$longitude" ]; then
            if generate_poi_json "$latitude" "$longitude" >&2; then
                cat /root/poi.json
            else
                echo "Error: Failed to generate POI JSON"
            fi
        fi

    else
        echo "Error: Unknown request"
    fi
}

if [ "${1:-}" = "--client" ]; then
    handle_client
    exit 0
fi

if [ -z "$server_ip" ]; then
    echo "Error: Cannot find server IP"
    exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
    echo "Error: socat is not installed"
    exit 1
fi


echo "The server is running at Link addr:$server_ip"

listen_port="${SERVER_PORT:-1234}"

socat TCP-LISTEN:"$listen_port",reuseaddr,fork \
    EXEC:"bash /root/server.sh --client" &

listener_pid=$!

trap 'kill "$listener_pid" 2>/dev/null; wait "$listener_pid" 2>/dev/null' EXIT

sleep 1

server_port=$(ss -ltn | awk -v port="$listen_port" '
    NR > 1 {
        n = split($4, parts, ":")
        if (parts[n] == port) {
            print parts[n]
            exit
        }
    }
')

if [ -z "$server_port" ]; then
    echo "Error: Cannot detect server port"
    exit 1
fi

echo "Server listening on port: $server_port"
echo "Waiting for client..."

wait "$listener_pid"
