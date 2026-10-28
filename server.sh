#!/bin/bash

server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

if [ -z "$server_ip" ]; then
    echo "Error: Cannot find server IP"
    exit 1
fi

echo "The server is running at Link addr:$server_ip"

while true
do
    echo "Waiting for client..."
    nc -v -l 1234
done
