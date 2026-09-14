#!/usr/bin/env bash
set -e

echo "Funnel + S3 Installer"

# ---- Detect Operating System ----

OS=$(uname -s)
ARCH=$(uname -m)

echo "Detected OS: $OS ($ARCH)"


# ---- Determine RustFS client (rc) URL ----

# MinIO archived mc and pulled it from dl.min.io. RustFS ships its own CLI (rc)
# which drives the same admin API, so pin a release and verify its checksum.

RC_VERSION="v0.1.35"
RC_PLATFORM=""
RC_SHA256=""

if [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        RC_PLATFORM="linux-arm64"
        RC_SHA256="3d8e125f878f295dedeb40a03a85c311588205601f5076fbc8b341fe40b41b1b"
    else
        RC_PLATFORM="linux-amd64"
        RC_SHA256="f852392837e2b56c4785ea7f4e4a0e3f58a5df19fe317eb80bcc1bfaa41a2893"
    fi

elif [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
        RC_PLATFORM="macos-arm64"
        RC_SHA256="2ab756c1a55c13532a65e6ef78c2eab2e0d4321e81f251313b3fba860840d5c8"
    else
        RC_PLATFORM="macos-amd64"
        RC_SHA256="3be929f5d1cae028f143ba0c3557484e8df771c03b7105f98e1c87e5abb7f985"
    fi
else
    echo "Unsupported OS: $OS"
    exit 1
fi

RC_URL="https://github.com/rustfs/cli/releases/download/${RC_VERSION}/rustfs-cli-${RC_PLATFORM}-${RC_VERSION}.tar.gz"


# ---- Install RustFS Client (rc) -----

if ! command -v rc &>/dev/null; then
    echo "Installing RustFS client (rc) ${RC_VERSION} for ${RC_PLATFORM}..."
    echo "Download URL: $RC_URL"

    RC_TMPDIR=$(mktemp -d)
    trap 'rm -rf "$RC_TMPDIR"' EXIT

    # -f so an HTTP error fails the download instead of saving the error page.
    curl -fL "$RC_URL" -o "$RC_TMPDIR/rc.tar.gz"

    if command -v sha256sum &>/dev/null; then
        echo "${RC_SHA256}  ${RC_TMPDIR}/rc.tar.gz" | sha256sum -c -
    else
        # macOS has shasum rather than sha256sum.
        echo "${RC_SHA256}  ${RC_TMPDIR}/rc.tar.gz" | shasum -a 256 -c -
    fi

    tar -xzf "$RC_TMPDIR/rc.tar.gz" -C "$RC_TMPDIR" rc
    sudo install -m 0755 "$RC_TMPDIR/rc" /usr/local/bin/rc
else
    echo "rc is already installed."
fi


# ---- Login to S3 TRE ----

echo "Configuring S3 client..."

rc alias set tre-s3 http://localhost:9002 s3-tre s3-tre-pass || {
    echo "ERROR: Unable to connect to S3 TRE."
    echo "Make sure S3 TRE is running at http://localhost:9002"
    exit 1
}


# ---- Create Access Keys ----

# `rc admin service-account create` takes the credentials as arguments, whereas
# `mc admin user svcacct add` generated them and printed them back. Mint a
# random pair here and hand it to rc.

echo "Creating S3 TRE service account..."

rand_str() { LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$1"; }

ACCESS_KEY="funnel$(rand_str 14)"
SECRET_KEY=$(rand_str 40)

rc admin service-account create tre-s3 "$ACCESS_KEY" "$SECRET_KEY" \
    --user s3-tre \
    --name funnel >/dev/null || {
    echo "ERROR: Unable to create the S3 TRE service account."
    exit 1
}


# ---- Install Funnel ----

echo "Checking for Funnel installation..."

FUNNEL_VERSION="v0.11.12"
FUNNEL_DEST="$HOME/.local/bin"

export PATH="$FUNNEL_DEST:$PATH"

CURRENT_FUNNEL_VERSION=""
if command -v funnel &>/dev/null; then
    CURRENT_FUNNEL_VERSION="$(funnel version 2>/dev/null | awk '/version:/ {print "v"$2; exit}')"
fi

if [[ "$CURRENT_FUNNEL_VERSION" != "$FUNNEL_VERSION" ]]; then
    echo "Installing Funnel $FUNNEL_VERSION..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/calypr/funnel/develop/install.sh)" -- "$FUNNEL_VERSION" "$FUNNEL_DEST"
else
    echo "Funnel $FUNNEL_VERSION is already installed."
fi


# ---- Create Funnel config.yml ----

FUNNEL_WORK_DIR="./funnel-work-dir"

echo "Creating funnel-config.yml..."

cat <<EOF > "./config/funnel-config.yml"
GenericS3:
  - Disabled: false
    Endpoint: "localhost:9002"
    Key: "$ACCESS_KEY"
    Secret: "$SECRET_KEY"
    Region: "us-east-1"

Worker:
  WorkDir: "$FUNNEL_WORK_DIR"

EOF


# ---- Run Funnel Server ----

echo "Starting Funnel..."
cd ./config
funnel server run -c funnel-config.yml