#!/usr/bin/env bash
#
# setup-data-library.sh
#
# Creates the "Northwind Home Docs" Agentforce Data Library (Salesforce Drive source, enhanced
# index), uploads the four PDFs from docs/pdf and writes the library's retriever API name into
# the NW_Doc_* prompt templates.
#
# Usage: scripts/setup-data-library.sh <step> [<step> ...]
#
#   preflight  Check the org ID, that data libraries are available and the PDFs exist
#   create     Create the library, unless one named LIB_DEV_NAME already exists
#   upload     Upload the PDFs, waiting up to WAIT_MINUTES for indexing. If the library already
#              has some files, only the missing ones are added.
#   wait       Poll until the library has a retriever, or stop if indexing fails
#   resolve    Look up the retriever API name and save it to $WORK_DIR/retriever.apiName
#   apply      Replace __RETRIEVER_API_NAME__ in the three prompt templates and check the result
#   status     Show indexing stages, artifacts and files
#   all        preflight, create, upload, wait, resolve, apply
#
# preflight, wait, resolve and status only read from the org. With DRY_RUN=1, org changes and
# template edits are printed instead of made.
#
# Environment (defaults shown):
#   TARGET_ORG=northwind-dev   EXPECTED_ORG_ID=   (empty: the org ID is not checked)
#   LIB_NAME="Northwind Home Docs"       LIB_DEV_NAME=Northwind_Home_Docs
#   INDEX_MODE=enhanced                  WAIT_MINUTES=45   POLL_SECONDS=30
#   WORK_DIR=$TMPDIR/nw-data-library
#   RETRIEVER_API_NAME   set to skip the lookup and use this name in apply
#
# apply edits files and needs no org, so it runs without TARGET_ORG.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ORG="${TARGET_ORG:-northwind-dev}"
EXPECTED_ORG_ID="${EXPECTED_ORG_ID:-}"
LIB_NAME="${LIB_NAME:-Northwind Home Docs}"
LIB_DEV_NAME="${LIB_DEV_NAME:-Northwind_Home_Docs}"
LIB_DESCRIPTION="${LIB_DESCRIPTION:-Northwind Home warranty, returns and refunds, Aura T200 manual and CarePlus SLA PDFs for the Northwind Service Agent.}"
INDEX_MODE="${INDEX_MODE:-enhanced}"
WAIT_MINUTES="${WAIT_MINUTES:-45}"
POLL_SECONDS="${POLL_SECONDS:-30}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/nw-data-library}"
DRY_RUN="${DRY_RUN:-0}"
PDF_DIR="$PROJECT_ROOT/docs/pdf"
PDFS=(
  "$PDF_DIR/01-warranty-policy.pdf"
  "$PDF_DIR/02-returns-refunds-policy.pdf"
  "$PDF_DIR/03-aura-thermostat-t200-manual.pdf"
  "$PDF_DIR/04-careplus-service-plans-sla.pdf"
)
TEMPLATE_DIR="$PROJECT_ROOT/force-app/main/default/genAiPromptTemplates"
TEMPLATES=(
  "$TEMPLATE_DIR/NW_Doc_Answer_Question.genAiPromptTemplate-meta.xml"
  "$TEMPLATE_DIR/NW_Doc_Summarize.genAiPromptTemplate-meta.xml"
  "$TEMPLATE_DIR/NW_Doc_Extract_Details.genAiPromptTemplate-meta.xml"
)
PLACEHOLDER="__RETRIEVER_API_NAME__"

log()  { printf '[data-library] %s\n' "$*" >&2; }
die()  { printf '[data-library] ERROR: %s\n' "$*" >&2; exit 1; }

# sf_json <sf args...>: runs `sf <args> --json` with stdout in SF_OUT and stderr in SF_ERR,
# and returns the sf exit code. Only stdout is parsed; the CLI writes update notices to stderr.
sf_json() {
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/data-library-err.XXXXXX")"
  SF_OUT="$(sf "$@" --json 2>"$errf")" || rc=$?
  SF_ERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  return "$rc"
}

# jq_py <json> <python expression on d>; prints an empty string if the path is missing
jq_py() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    v = eval(sys.argv[2], {"d": d})
    print("" if v is None else v)
except Exception:
    print("")
' "$1" "$2"
}

mutate_print() { printf '[data-library] DRY_RUN would run:' >&2; printf ' %q' "$@" >&2; printf '\n' >&2; }

has_placeholder() { case "$1" in *__*__*) return 0 ;; *) return 1 ;; esac; } # a __NAME__ value from the repository

guard_org() {
  has_placeholder "$EXPECTED_ORG_ID" && die "EXPECTED_ORG_ID is still the placeholder '$EXPECTED_ORG_ID'; set it to the org ID of '$TARGET_ORG'"
  sf_json org display -o "$TARGET_ORG" || die "cannot read org '$TARGET_ORG'. Log in with 'sf org login web -a $TARGET_ORG' or set TARGET_ORG"
  local id
  id="$(jq_py "$SF_OUT" "d['result']['id']")"
  if [ -z "$EXPECTED_ORG_ID" ]; then
    [ -n "${ORG_ID_WARNED:-}" ] || { log "WARNING: EXPECTED_ORG_ID is not set, so the org ID is not checked"; ORG_ID_WARNED=1; }
  fi
  [ -z "$EXPECTED_ORG_ID" ] || [ "${id:0:15}" = "${EXPECTED_ORG_ID:0:15}" ] || die "org id '$id' != expected $EXPECTED_ORG_ID; refusing to continue"
  log "org guard ok: $TARGET_ORG is $id"
}

library_id() { # prints the library ID (1JD...) for LIB_DEV_NAME, or nothing; cached in $WORK_DIR/library.id
  if [ -s "$WORK_DIR/library.id" ]; then cat "$WORK_DIR/library.id"; return 0; fi
  sf_json agent adl list -o "$TARGET_ORG" || die "sf agent adl list failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
  jq_py "$SF_OUT" "next((l['libraryId'] for l in d['result']['libraries'] if l.get('developerName') == '$LIB_DEV_NAME'), '')"
}

require_library() {
  LIB_ID="$(library_id)"
  if [ -z "$LIB_ID" ]; then
    [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: library $LIB_DEV_NAME does not exist yet; '$1' would run after create"; return 1; }
    die "library $LIB_DEV_NAME not found; run create first"
  fi
  return 0
}

step_preflight() {
  command -v sf >/dev/null || die "sf not on PATH"
  command -v python3 >/dev/null || die "python3 not on PATH"
  guard_org
  local f
  for f in "${PDFS[@]}"; do [ -s "$f" ] || die "missing PDF: $f"; done
  log "4 PDFs present in $PDF_DIR"
  if ! sf_json agent adl list -o "$TARGET_ORG"; then
    die "sf agent adl list failed (Data Cloud provisioning not finished?): $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
  fi
  log "data libraries in org: $(jq_py "$SF_OUT" "[(l['developerName'], l['libraryId'], l['status']) for l in d['result']['libraries']]")"
}

step_create() {
  guard_org
  local existing
  existing="$(library_id)"
  if [ -n "$existing" ]; then
    log "library $LIB_DEV_NAME already exists ($existing); skipping create"
    printf '%s\n' "$existing" > "$WORK_DIR/library.id"
    return 0
  fi
  local args=(agent adl create -o "$TARGET_ORG" --name "$LIB_NAME" --developer-name "$LIB_DEV_NAME"
              --description "$LIB_DESCRIPTION" --source-type sfdrive --index-mode "$INDEX_MODE")
  if [ "$DRY_RUN" = "1" ]; then mutate_print sf "${args[@]}" --json; return 0; fi
  sf_json "${args[@]}" || die "sf agent adl create failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
  LIB_ID="$(jq_py "$SF_OUT" "d['result']['libraryId']")"
  [ -n "$LIB_ID" ] || die "create returned no libraryId: $SF_OUT"
  printf '%s\n' "$LIB_ID" > "$WORK_DIR/library.id"
  log "created library $LIB_DEV_NAME: $LIB_ID"
}

step_upload() {
  guard_org
  require_library upload || return 0
  sf_json agent adl file list -i "$LIB_ID" -o "$TARGET_ORG" --page-size 200 || die "file list failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
  local present missing=() f
  present="$(jq_py "$SF_OUT" "'|'.join(x.get('fileName','') for x in d['result'].get('files') or [])")"
  for f in "${PDFS[@]}"; do
    case "|$present|" in *"|$(basename "$f")|"*) log "already in library: $(basename "$f")" ;; *) missing+=("$f") ;; esac
  done
  if [ "${#missing[@]}" -eq 0 ]; then log "all 4 PDFs already uploaded"; return 0; fi
  local args=()
  if [ -z "$present" ]; then
    args=(agent adl upload -i "$LIB_ID" -o "$TARGET_ORG" --wait "$WAIT_MINUTES")
    for f in "${missing[@]}"; do args+=(-f "$f"); done
  else
    args=(agent adl file add -i "$LIB_ID" -o "$TARGET_ORG")
    for f in "${missing[@]}"; do args+=(--path "$f"); done
  fi
  if [ "$DRY_RUN" = "1" ]; then mutate_print sf "${args[@]}" --json; return 0; fi
  log "uploading ${#missing[@]} file(s); this can take up to $WAIT_MINUTES minutes"
  if ! sf_json "${args[@]}"; then
    # Indexing continues after an UploadTimeout, so carry on and let the wait step poll.
    log "WARNING: sf ${args[1]} ${args[2]} returned an error: $(jq_py "$SF_OUT" "d.get('name')") $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
    [ "$(jq_py "$SF_OUT" "d.get('name')")" = "UploadTimeout" ] || die "upload failed; check 'sf agent adl status -i $LIB_ID --include-artifacts'"
  fi
  log "upload result: $(jq_py "$SF_OUT" "d.get('result')")"
}

step_wait() {
  guard_org
  require_library wait || return 0
  local i max status ret
  max=$(( (WAIT_MINUTES * 60) / POLL_SECONDS + 1 ))
  for ((i = 1; i <= max; i++)); do
    sf_json agent adl get -i "$LIB_ID" -o "$TARGET_ORG" || die "adl get failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
    status="$(jq_py "$SF_OUT" "d['result'].get('status')")"
    ret="$(jq_py "$SF_OUT" "d['result'].get('retrieverId')")"
    if [ -n "$ret" ]; then log "library status $status, retrieverId $ret"; break; fi
    [ "$status" = "FAILED" ] && die "library indexing FAILED; see 'sf agent adl status -i $LIB_ID --include-artifacts'"
    log "[$i/$max] status=${status:-?}, retriever not ready; waiting ${POLL_SECONDS}s"
    [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: not polling further"; return 0; }
    sleep "$POLL_SECONDS"
  done
  [ -n "$ret" ] || die "retriever not ready after $WAIT_MINUTES minutes"
  sf_json agent adl file list -i "$LIB_ID" -o "$TARGET_ORG" --page-size 200 || true
  log "files: $(jq_py "$SF_OUT" "[(x.get('fileName'), x.get('status')) for x in d['result'].get('files') or []]")"
}

step_resolve() {
  guard_org
  if [ -n "${RETRIEVER_API_NAME:-}" ]; then
    has_placeholder "$RETRIEVER_API_NAME" && die "RETRIEVER_API_NAME is still the placeholder '$RETRIEVER_API_NAME'; set it to the name from Prompt Builder or leave it empty"
    printf '%s\n' "$RETRIEVER_API_NAME" > "$WORK_DIR/retriever.apiName"; log "using RETRIEVER_API_NAME=$RETRIEVER_API_NAME"; return 0
  fi
  require_library resolve || return 0
  local name=""
  sf_json agent adl get -i "$LIB_ID" -o "$TARGET_ORG" || die "adl get failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
  name="$(jq_py "$SF_OUT" "(d['result'].get('retriever') or {}).get('apiName')")"
  log "adl get: retriever=$(jq_py "$SF_OUT" "d['result'].get('retriever')") retrieverAction=$(jq_py "$SF_OUT" "d['result'].get('retrieverAction')")"
  if [ -z "$name" ]; then
    sf_json agent adl status -i "$LIB_ID" -o "$TARGET_ORG" --include-artifacts || die "adl status failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
    name="$(jq_py "$SF_OUT" "next((a.get('apiName') for s in d['result']['indexingStatus'].get('stageDetails') or [] if s.get('name') == 'RETRIEVER' for a in s.get('artifacts') or [] if a.get('apiName')), '')")"
    log "adl status RETRIEVER stage: $(jq_py "$SF_OUT" "[s for s in d['result']['indexingStatus'].get('stageDetails') or [] if s.get('name') == 'RETRIEVER']")"
  fi
  if [ -z "$name" ]; then
    [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: retriever API name not available yet"; return 0; }
    die "retriever API name not found; read it in Prompt Builder (Insert Resource > Retrievers) and re-run with RETRIEVER_API_NAME=<name> $0 apply"
  fi
  case "$name" in *[!A-Za-z0-9_]*) die "unexpected retriever API name '$name' (expected letters, digits, underscores)";; esac
  printf '%s\n' "$name" > "$WORK_DIR/retriever.apiName"
  log "retriever API name: $name"
  printf '%s\n' "$name"
}

step_apply() {
  local name="${RETRIEVER_API_NAME:-}" f count
  [ -n "$name" ] || { [ -s "$WORK_DIR/retriever.apiName" ] && name="$(cat "$WORK_DIR/retriever.apiName")"; }
  if [ -z "$name" ]; then
    [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: no retriever API name yet; apply would replace $PLACEHOLDER in ${#TEMPLATES[@]} templates"; return 0; }
    die "no retriever API name; run resolve first or set RETRIEVER_API_NAME"
  fi
  case "$name" in *[!A-Za-z0-9_]*) die "unexpected retriever API name '$name'";; esac
  has_placeholder "$name" && die "retriever API name '$name' is a placeholder; set RETRIEVER_API_NAME to the name from Prompt Builder"
  for f in "${TEMPLATES[@]}"; do
    count="$(grep -c "$PLACEHOLDER" "$f" || true)"
    if [ "$count" = "0" ]; then
      grep -q "$name" "$f" && { log "already applied: $(basename "$f")"; continue; }
      die "$(basename "$f") has no $PLACEHOLDER and does not contain $name (edited by hand?)"
    fi
    if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN: would replace $count line(s) of $PLACEHOLDER with $name in $(basename "$f")"; continue; fi
    # -i.bak works with both BSD (macOS) and GNU sed
    sed -i.bak "s/${PLACEHOLDER}/${name}/g" "$f" && rm -f "$f.bak"
  done
  [ "$DRY_RUN" = "1" ] && return 0
  for f in "${TEMPLATES[@]}"; do
    [ "$(grep -c "$PLACEHOLDER" "$f" || true)" = "0" ] || die "placeholder still present in $f"
    [ "$(grep -o "$name" "$f" | wc -l | tr -d ' ')" = "3" ] || die "expected 3 occurrences of $name in $f"
    if command -v xmllint >/dev/null; then xmllint --noout "$f" || die "invalid XML: $f"; fi
  done
  log "applied $name to ${#TEMPLATES[@]} prompt templates (0 placeholders left, 3 hits each)"
}

step_status() {
  guard_org
  require_library status || return 0
  sf_json agent adl status -i "$LIB_ID" -o "$TARGET_ORG" --include-artifacts || die "adl status failed: $(jq_py "$SF_OUT" "d.get('message')") $SF_ERR"
  log "status: $(jq_py "$SF_OUT" "d['result']['indexingStatus'].get('status')")"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for s in d["result"]["indexingStatus"].get("stageDetails") or []:
    print("[data-library]   %s: %s %s" % (s.get("name"), s.get("status"), s.get("error") or ""), file=sys.stderr)
    for a in s.get("artifacts") or []:
        print("[data-library]     %s: %s (%s)" % (a.get("assetType"), a.get("apiName") or a.get("label"), a.get("id")), file=sys.stderr)
' "$SF_OUT"
  sf_json agent adl file list -i "$LIB_ID" -o "$TARGET_ORG" --page-size 200 || true
  log "files: $(jq_py "$SF_OUT" "[(x.get('fileName'), x.get('status')) for x in d['result'].get('files') or []]")"
}

main() {
  [ "$#" -ge 1 ] || { sed -n '3,31p' "$0"; exit 2; }
  mkdir -p "$WORK_DIR"
  local s
  for s in "$@"; do
    case "$s" in
      preflight) step_preflight ;;
      create)    step_create ;;
      upload)    step_upload ;;
      wait)      step_wait ;;
      resolve)   step_resolve ;;
      apply)     step_apply ;;
      status)    step_status ;;
      all)       step_preflight; step_create; step_upload; step_wait; step_resolve; step_apply ;;
      *) die "unknown step '$s' (preflight|create|upload|wait|resolve|apply|status|all)" ;;
    esac
  done
}

main "$@"
