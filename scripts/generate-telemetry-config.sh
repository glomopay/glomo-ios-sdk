#!/bin/sh

set -eu

MIXPANEL_VALUE="${GLOMOPAY_MIXPANEL_TOKEN:-${MIXPANEL_TOKEN:-}}"
SENTRY_VALUE="${GLOMOPAY_SENTRY_DSN:-${SENTRY_DSN:-}}"

if [ -z "$MIXPANEL_VALUE" ]; then
    echo "Missing GLOMOPAY_MIXPANEL_TOKEN (or MIXPANEL_TOKEN)." >&2
    exit 1
fi

if [ -z "$SENTRY_VALUE" ]; then
    echo "Missing GLOMOPAY_SENTRY_DSN (or SENTRY_DSN)." >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT="$SCRIPT_DIR/../Sources/GlomoPaySDK/Resources/GlomoPayTelemetryConfiguration.plist"

/usr/bin/plutil -create xml1 "$OUTPUT"
/usr/bin/plutil -insert GLOMOPAY_MIXPANEL_TOKEN -string "$MIXPANEL_VALUE" "$OUTPUT"
/usr/bin/plutil -insert GLOMOPAY_SENTRY_DSN -string "$SENTRY_VALUE" "$OUTPUT"

echo "Generated SDK telemetry configuration at $OUTPUT"
