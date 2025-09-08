#!/usr/bin/env bash
set -euo pipefail

# terraform.sh
# Manage terraform remote backend via SSM parameter or by running bootstrap terraform.
# Usage:
#   ./terraform.sh bootstrap [-e ENV] [-r REGION] [--target-dir PATH] [--app-name NAME]
#   ./terraform.sh plan|apply [-e ENV] [-r REGION] [--target-dir PATH] [--force-copy] [--app-name NAME]
#
# Behavior:
# - Synthesizes APP_NAME (from properties.${ENV}.json unless --app-name supplied) and ACCOUNT_ID.
# - Looks for SSM parameter at /terraform/${ACCOUNT_ID}-${SAFE_APP_NAME}.
#   - If found: writes its value to backend.hcl in the target dir and uses it for terraform init.
#   - If not found: runs bootstrap terraform (in bootstrap/), migrates state into S3/DynamoDB backend,
#     creates the SSM parameter with the backend.hcl contents, then uses it.

REGION="${AWS_REGION:-us-east-1}"
DYNAMODB_TABLE_OVERRIDE=""
BUCKET_OVERRIDE=""
TARGET_DIR_OVERRIDE=""
TARGET_DIR="${TARGET_DIR:-.}"
FORCE_COPY="false"
APP_NAME_OVERRIDE=""

COMMAND="init"

print_usage() {
  cat <<EOF
Usage:
  $0 bootstrap [-e ENV] [-r REGION] [--target-dir PATH] [--app-name NAME]
  $0 init|plan|apply [-e ENV] [-r REGION] [--target-dir PATH] [--force-copy] [--app-name NAME]

Commands:
  bootstrap   Run the bootstrap terraform in ./bootstrap to create remote backend and SSM entry.
  init        Ensure backend exists (via SSM or bootstrap), then run 'terraform init' in target dir.
  plan        Ensure backend exists (via SSM or bootstrap), init, then run 'terraform plan' in target dir.
  apply       Ensure backend exists (via SSM or bootstrap), init, then run 'terraform apply' in target dir.

Options:
  -e, --env           Environment (default: dev)
  -r, --region        AWS region (default: us-east-1)
  --target-dir        Target terraform directory to run init/plan/apply in (default: .)
  --force-copy        When migrating local state into newly created backend, pass -force-copy to terraform init
  --app-name          Override app name (otherwise read from properties.${ENV}.json)
  -h, --help          Show this help
EOF
}

# Parse command (first arg may be a command)
if [[ $# -ge 1 ]]; then
  case "$1" in
    bootstrap|init|plan|apply)
      COMMAND="$1"; shift || true
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -e|--env)
      ENV="$2"; shift; shift;;
    -r|--region)
      REGION="$2"; shift; shift;;
    --target-dir)
      TARGET_DIR_OVERRIDE="$2"; shift; shift;;
    --force-copy)
      FORCE_COPY="true"; shift;;
    --app-name)
      APP_NAME_OVERRIDE="$2"; shift; shift;;
    -h|--help)
      print_usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; print_usage; exit 1;;
  esac
done

# Set target dir
if [[ -n "$TARGET_DIR_OVERRIDE" ]]; then
  TARGET_DIR="$TARGET_DIR_OVERRIDE"
  mkdir -p "$TARGET_DIR"
else
  TARGET_DIR="."
fi

# Helpers
log() { printf '[%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Run a command while logging it. Accepts the command as arguments (preserves arrays).
run_and_log() {
  printf '[%s] CMD: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  "$@" || { err "Command failed: $*"; return 1; }
}

synthesize_app_name_and_account() {
  if [[ -n "$APP_NAME_OVERRIDE" ]]; then
    APP_NAME="$APP_NAME_OVERRIDE"
  else
    if [[ -f "properties.${ENV}.json" ]]; then
      APP_NAME=$(jq -r '.app_name' "properties.${ENV}.json")
    else
      APP_NAME=""
    fi
  fi

  if [[ -z "$APP_NAME" || "$APP_NAME" == "null" ]]; then
    err "Unable to determine app name. Ensure properties.${ENV}.json exists and contains an 'app_name' field, or provide --app-name."
    exit 2
  fi

  SAFE_APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
  if [[ -z "$ACCOUNT_ID" ]]; then
    err "Unable to determine AWS account id. Ensure AWS CLI is configured."
    exit 2
  fi

  SSM_PARAM_NAME="/terraform/backend/${ACCOUNT_ID}-${SAFE_APP_NAME}"
}

get_ssm_backend() {
  # Returns the parameter value or empty string if not found
  if aws ssm get-parameter --name "$SSM_PARAM_NAME" --with-decryption --region "$REGION" >/dev/null 2>&1; then
    aws ssm get-parameter --name "$SSM_PARAM_NAME" --with-decryption --query Parameter.Value --output text --region "$REGION"
  else
    echo ""
  fi
}

put_ssm_backend() {
  local value="$1"
  aws ssm put-parameter --name "$SSM_PARAM_NAME" --value "$value" --type String --overwrite --region "$REGION" >/dev/null
}

write_backend_hcl_to_file() {
  local content="$1"
  local out_path="$TARGET_DIR/backend.hcl"
  echo "$content" > "$out_path"
  log "Wrote $out_path"
}

build_backend_content() {
  # Arguments: bucket dynamodb region account
  local bucket="$1"; local dynamodb="$2"; local region="$3"; local account="$4"
  cat <<EOF
bucket = "${bucket}"
key    = "terraform.${account}-${region}-${SAFE_APP_NAME}.tfstate"
region = "${region}"
dynamodb_table = "${dynamodb}"
encrypt = true
EOF
}

erase_backend_tf() {
  local dir="$1"
  local backend_tf_path="$dir/backend.tf"
  if [[ -f "$backend_tf_path" ]]; then
    rm "$backend_tf_path"
  fi
  log "Erased backend.tf at $backend_tf_path"
}

ensure_minimal_backend_tf() {
  local dir="$1"
  local backend_tf_path="$dir/backend.tf"
  if [[ ! -f "$backend_tf_path" ]]; then
    cat > "$backend_tf_path" <<'TFEOF'
terraform {
  backend "s3" {}
}
TFEOF
    log "Created minimal backend.tf at $backend_tf_path"
  else
    log "Found existing backend.tf at $backend_tf_path"
  fi
}

run_terraform_init_with_backend_file() {
  pushd "$TARGET_DIR" >/dev/null
  INIT_CMD=(terraform init -backend-config="$(basename "$TARGET_DIR/backend.hcl")" -reconfigure -input=false)
  if [[ "$FORCE_COPY" == "true" ]]; then
    INIT_CMD+=( -force-copy )
  fi
  run_and_log "${INIT_CMD[@]}" || { popd >/dev/null; exit 1; }
  popd >/dev/null
}

run_bootstrap_and_create_ssm() {
  # Find bootstrap dir
  BOOTSTRAP_LOCATIONS=("${TARGET_DIR}/bootstrap" "bootstrap")
  local found=""
  for dir in "${BOOTSTRAP_LOCATIONS[@]}"; do
    if [[ -d "$dir" ]]; then
      found="$dir"
      break
    fi
  done
  if [[ -z "$found" ]]; then
    err "Bootstrap directory not found in ${BOOTSTRAP_LOCATIONS[*]}. Cannot bootstrap."
    exit 1
  fi

  log "Found bootstrap directory at $found. Running terraform init and apply..."
  erase_backend_tf "$found"

  pushd "$found" >/dev/null

  run_and_log terraform init -input=false -reconfigure || { err "terraform init failed in $found"; popd >/dev/null; exit 1; }

  run_and_log terraform apply -auto-approve -input=false -var "environment=${ENV}" -var "region=${REGION}" || { err "terraform apply failed in $found"; popd >/dev/null; exit 1; }

  log "Bootstrap terraform apply completed in $found."

  # After apply, build backend config and migrate bootstrap local state into remote
  # The bootstrap terraform is expected to output or create the S3 bucket and DynamoDB table names
  # We allow overrides via env variables if present
  if [[ -n "$BUCKET_OVERRIDE" ]]; then
    BUCKET_NAME="$BUCKET_OVERRIDE"
  else
    # attempt to read bucket name from terraform output if available
    if terraform output -json >/dev/null 2>&1; then
      if terraform output -json | jq -r 'select(has("bucket_name")) .bucket_name.value' >/dev/null 2>&1; then
        BUCKET_NAME=$(terraform output -json | jq -r '.bucket_name.value')
      fi
    fi
    BUCKET_NAME="${BUCKET_NAME:-${ACCOUNT_ID}-${SAFE_APP_NAME}-tfstate}"
  fi

  if [[ -n "$DYNAMODB_TABLE_OVERRIDE" ]]; then
    DYNAMODB_TABLE="$DYNAMODB_TABLE_OVERRIDE"
  else
    if terraform output -json >/dev/null 2>&1; then
      if terraform output -json | jq -r 'select(has("dynamodb_table_name")) .dynamodb_table_name.value' >/dev/null 2>&1; then
        DYNAMODB_TABLE=$(terraform output -json | jq -r '.dynamodb_table_name.value')
      fi
    fi
    DYNAMODB_TABLE="${DYNAMODB_TABLE:-${ACCOUNT_ID}-${SAFE_APP_NAME}-tflocks}"
  fi

  # Migrate bootstrap state into new remote backend
  log "Migrating bootstrap terraform state to remote backend (S3 + DynamoDB)..."

  ensure_minimal_backend_tf "."

  run_and_log terraform init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET_NAME}" \
    -backend-config="key=bootstrap.terraform.${ACCOUNT_ID}-${REGION}-${SAFE_APP_NAME}.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="dynamodb_table=${DYNAMODB_TABLE}" \
    -backend-config="encrypt=true" -force-copy || { err "bootstrap terraform init (migration) failed in $found"; popd >/dev/null; exit 1; }

  popd >/dev/null

  # Build backend.hcl content for the main target
  backend_content=$(build_backend_content "${BUCKET_NAME}" "${DYNAMODB_TABLE}" "${REGION}" "${ACCOUNT_ID}")

  # Store into SSM
  put_ssm_backend "$backend_content"
  log "Stored backend configuration into SSM parameter $SSM_PARAM_NAME"

  # Write backend file to target dir
  write_backend_hcl_to_file "$backend_content"
}

ensure_backend_via_ssm_or_bootstrap() {
  # Return with backend.hcl in $TARGET_DIR/backend.hcl ready and SSM param present
  local ssm_value
  ssm_value=$(get_ssm_backend) || ssm_value=""
  if [[ -n "$ssm_value" && "$ssm_value" != "None" ]]; then
    log "Found backend configuration in SSM $SSM_PARAM_NAME"
    write_backend_hcl_to_file "$ssm_value"
  else
    log "Backend SSM parameter $SSM_PARAM_NAME not found or empty. Running bootstrap to create backend and SSM entry."
    run_bootstrap_and_create_ssm
  fi
}

# Main
synthesize_app_name_and_account

case "$COMMAND" in
  bootstrap)
    run_bootstrap_and_create_ssm
    log "Bootstrap completed. You can now run terraform init/plan/apply in $TARGET_DIR using the SSM-provided backend."
    ;;
  init)
    ensure_backend_via_ssm_or_bootstrap
    ensure_minimal_backend_tf "$TARGET_DIR"
    run_terraform_init_with_backend_file
    ;;
  plan)
    ensure_backend_via_ssm_or_bootstrap
    ensure_minimal_backend_tf "$TARGET_DIR"
    run_terraform_init_with_backend_file
    pushd "$TARGET_DIR" >/dev/null
    run_and_log terraform plan -input=false -var "environment=${ENV}" -var "region=${REGION}"
    popd >/dev/null
    ;;
  apply)
    ensure_backend_via_ssm_or_bootstrap
    ensure_minimal_backend_tf "$TARGET_DIR"
    run_terraform_init_with_backend_file
    pushd "$TARGET_DIR" >/dev/null
    run_and_log terraform apply -auto-approve -input=false -var "environment=${ENV}" -var "region=${REGION}"
    popd >/dev/null
    ;;
  *)
    # default: init only (backwards compatible)
    print_usage
    exit 1
    ;;
esac

log "Done." 