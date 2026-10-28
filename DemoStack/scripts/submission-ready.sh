#!/usr/bin/env bash
set -e

# Make sure to give permissions to execute this script: chmod +x real-sub-setup.sh
# ----------------------------------


# ---- Verify .env File Exists ----

ENV_FILE="./.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at: $ENV_FILE"
    exit 1
fi
echo "Found .env file."


# ---- Apply configuration changes BEFORE cd ----

echo "Updating .env..."

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    sed -i '' "s|^SeedDemoData=.*|SeedDemoData=false|" "$ENV_FILE"
    sed -i '' "s|^UseTESK=.*|UseTESK=true|" "$ENV_FILE"
else
    # Linux and others
    sed -i "s|^SeedDemoData=.*|SeedDemoData=false|" "$ENV_FILE"
    sed -i "s|^UseTESK=.*|UseTESK=true|" "$ENV_FILE"
fi

echo ".env updated successfully."


# ---- Restart Docker Compose ----
echo "Restarting Docker Compose..."

docker compose down

if docker compose up -d; then
    echo "Docker Compose completed successfully."
    echo "   All containers are now started..."
else
    echo "ERROR: Docker Compose failed to start all services."
    exit 1
fi


# ---- Note ----
# Run this command to give access to the real-sub-setup.sh.
# - chmod +x real-sub-setup.sh