#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/release/app-store/logs"
PROFILE_OUTPUT="${PACE_PROFILE_OUTPUT:-$ROOT_DIR/release/app-store/Pace-AppStore.provisionprofile}"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/submit-$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

run() {
  log "run=$*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

cd "$ROOT_DIR"

log "app_store_submission=start log=\"$LOG_FILE\""

run "$ROOT_DIR/scripts/install-local-transporter.sh"
run "$ROOT_DIR/scripts/generate-app-store-screenshots.sh"

if [[ -n "${PACE_PROVISIONING_PROFILE:-}" ]]; then
  log "profile_import=attempt path=\"$PACE_PROVISIONING_PROFILE\""
  PACE_PROFILE_OUTPUT="$PROFILE_OUTPUT" "$ROOT_DIR/scripts/import-provisioning-profile.sh" "$PACE_PROVISIONING_PROFILE" 2>&1 | tee -a "$LOG_FILE"
fi

if [[ -z "${PACE_PROVISIONING_PROFILE:-}" && -n "${PACE_ASC_API_KEY:-}" && -n "${PACE_ASC_API_ISSUER:-}" ]]; then
  log "profile_fetch=attempt output=\"$PROFILE_OUTPUT\""
  PACE_PROFILE_OUTPUT="$PROFILE_OUTPUT" node "$ROOT_DIR/scripts/fetch-app-store-profile.mjs" 2>&1 | tee -a "$LOG_FILE"
fi

if [[ -z "${PACE_PROVISIONING_PROFILE:-}" && -f "$PROFILE_OUTPUT" ]]; then
  export PACE_PROVISIONING_PROFILE="$PROFILE_OUTPUT"
  log "provisioning_profile=using path=\"$PACE_PROVISIONING_PROFILE\""
fi

run "$ROOT_DIR/scripts/package-app-store.sh"

if ! "$ROOT_DIR/scripts/verify-app-store-readiness.sh" 2>&1 | tee -a "$LOG_FILE"; then
  PACE_BLOCKER_REPORT_PATH="$LOG_DIR/blocker-report-$TIMESTAMP.json" node "$ROOT_DIR/scripts/write-app-store-blocker-report.mjs" 2>&1 | tee -a "$LOG_FILE" || true
  log "app_store_submission=blocked stage=readiness log=\"$LOG_FILE\""
  exit 90
fi

if ! "$ROOT_DIR/scripts/upload-app-store.sh" 2>&1 | tee -a "$LOG_FILE"; then
  log "app_store_submission=blocked stage=upload log=\"$LOG_FILE\""
  exit 91
fi

if [[ -n "${PACE_ASC_API_KEY:-}" && -n "${PACE_ASC_API_ISSUER:-}" ]]; then
  if ! node "$ROOT_DIR/scripts/check-app-store-builds.mjs" 2>&1 | tee -a "$LOG_FILE"; then
    log "app_store_submission=pending stage=processing_check log=\"$LOG_FILE\""
    exit 92
  fi
else
  log "app_store_submission=submitted stage=processing_check_skipped reason=missing_api_credentials log=\"$LOG_FILE\""
  exit 0
fi

log "app_store_submission=pass log=\"$LOG_FILE\""
