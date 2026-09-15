#!/usr/bin/env bash
#
# setup-agent-user.sh
#
# Sets up the users for the Northwind Service Agent. Each record is looked up before it is
# created, so the script can be run again safely.
#
#   1. The agent user the service agent runs as (Einstein Agent User profile), with the
#      AgentforceServiceAgentUserPsl and GenieDataPlatformStarterPsl licenses and the
#      AgentforceServiceAgentUser and GenieUserEnhancedSecurity (Data Cloud User) permission
#      sets, plus any in EXTRA_AGENT_PERMSETS.
#   2. The org admin as the live support specialist, with the Service Cloud User, Enhanced
#      Chat User and (if available) Messaging User licenses and the NW_Live_Support_Agent
#      permission set. Deploy the permission set first.
#   3. The admin added to the NW_Live_Support queue.
#
# Usage: scripts/setup-agent-user.sh [org-alias]
#
# The last line on stdout is the agent username.
#
# Environment:
#   TARGET_ORG            used when no argument is given (default: northwind-dev)
#   EXPECTED_ORG_ID       stop unless the org has this ID (default: empty, not checked)
#   ADMIN_USERNAME        live support user (default: the user the CLI is logged in as)
#   AGENT_USERNAME        default: nwagent.<admin username>
#   AGENT_LASTNAME        default: Service Agent
#   EXTRA_AGENT_PERMSETS  comma-separated permission set API names for the agent user
#   SKIP_ADMIN=1          skip steps 2 and 3
#   DRY_RUN=1             report what would be created without writing anything
#
# Requires an authenticated sf CLI and python3.

set -euo pipefail

TARGET_ORG="${1:-${TARGET_ORG:-northwind-dev}}"
EXPECTED_ORG_ID="${EXPECTED_ORG_ID:-}"
AGENT_PROFILE_NAME="Einstein Agent User"
AGENT_LASTNAME="${AGENT_LASTNAME:-Service Agent}"
AGENT_ALIAS="nwagent"
AGENT_PSLS=("AgentforceServiceAgentUserPsl" "GenieDataPlatformStarterPsl")
AGENT_PERMSETS=("AgentforceServiceAgentUser" "GenieUserEnhancedSecurity")
ADMIN_REQUIRED_PSLS=("ServiceUserPsl" "EmbeddedServiceMessagingUserPsl")
ADMIN_OPTIONAL_PSLS=("LiveMessageUserPsl")
ADMIN_PERMSETS=("NW_Live_Support_Agent")
QUEUE_DEVELOPER_NAME="NW_Live_Support"
DRY_RUN="${DRY_RUN:-0}"
SKIP_ADMIN="${SKIP_ADMIN:-0}"
WARNINGS=()

log()  { printf '%s\n' "$*" >&2; }
# Logs the result of a write, marked as not done under DRY_RUN=1.
done_log() { if [ "$DRY_RUN" = "1" ]; then log "  [dry-run, not done] $*"; else log "  $*"; fi; }
warn() { WARNINGS+=("$*"); printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v sf >/dev/null 2>&1 || die "Salesforce CLI 'sf' not found on PATH."
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH."

# Escape a value for use inside single quotes in SOQL.
soql_escape() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }

# soql_first "<soql>" <Field>: prints the field from the first record, or nothing if there
# are no records. Dotted relationship fields such as Profile.Name work.
soql_first() {
  local soql="$1" field="$2" out
  if ! out=$(sf data query --target-org "$TARGET_ORG" --query "$soql" --json 2>/dev/null); then
    printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print("SOQL error: "+d.get("message",""), file=sys.stderr)
except Exception: pass' || true
    return 1
  fi
  printf '%s' "$out" | python3 -c '
import json, sys
field = sys.argv[1]
recs = json.load(sys.stdin).get("result", {}).get("records", [])
if recs:
    v = recs[0]
    for part in field.split("."):
        v = (v or {}).get(part)
    print("" if v is None else v)
' "$field"
}

# create_record <SObject> "<Field='value' ...>": prints the new record ID.
create_record() {
  local sobject="$1" values="$2" out
  if [ "$DRY_RUN" = "1" ]; then
    log "  [dry-run] would create $sobject: $values"
    printf 'DRYRUN'
    return 0
  fi
  if ! out=$(sf data create record --target-org "$TARGET_ORG" --sobject "$sobject" --values "$values" --json 2>/dev/null); then
    printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("message",""), file=sys.stderr)
except Exception: pass' || true
    return 1
  fi
  printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])'
}

# ensure_psl <userId> <pslDeveloperName> <required 1|0>
# Assigns the permission set license unless the user already has it. A missing optional
# license is logged but not counted as a warning.
ensure_psl() {
  local user_id="$1" psl_dev="$2" required="$3" psl_id existing
  psl_id=$(soql_first "SELECT Id FROM PermissionSetLicense WHERE DeveloperName = '$(soql_escape "$psl_dev")'" Id) || psl_id=""
  if [ -z "$psl_id" ]; then
    if [ "$required" = "1" ]; then warn "PSL $psl_dev not found in org."; else log "  PSL $psl_dev not found (optional) - skipped"; fi
    return 0
  fi
  existing=$(soql_first "SELECT Id FROM PermissionSetLicenseAssign WHERE AssigneeId = '$user_id' AND PermissionSetLicenseId = '$psl_id'" Id) || existing=""
  if [ -n "$existing" ]; then
    log "  PSL $psl_dev already assigned"
    return 0
  fi
  if create_record PermissionSetLicenseAssign "AssigneeId='$user_id' PermissionSetLicenseId='$psl_id'" >/dev/null; then
    done_log "PSL $psl_dev assigned"
  else
    if [ "$required" = "1" ]; then warn "Could not assign PSL $psl_dev (no seats left or license mismatch)."; else log "  PSL $psl_dev could not be assigned (optional) - skipped"; fi
  fi
}

# ensure_permset <userId> <permSetName>: assigns the permission set unless already assigned.
ensure_permset() {
  local user_id="$1" ps_name="$2" ps_id existing
  ps_id=$(soql_first "SELECT Id FROM PermissionSet WHERE Name = '$(soql_escape "$ps_name")'" Id) || ps_id=""
  if [ -z "$ps_id" ]; then
    warn "Permission set $ps_name not found in org (deploy it first, then re-run)."
    return 0
  fi
  existing=$(soql_first "SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '$user_id' AND PermissionSetId = '$ps_id'" Id) || existing=""
  if [ -n "$existing" ]; then
    log "  Permission set $ps_name already assigned"
    return 0
  fi
  if create_record PermissionSetAssignment "AssigneeId='$user_id' PermissionSetId='$ps_id'" >/dev/null; then
    done_log "Permission set $ps_name assigned"
  else
    warn "Could not assign permission set $ps_name (check the user's license / PSLs)."
  fi
}

# Org and admin user
log "== Target org: $TARGET_ORG"
case "$EXPECTED_ORG_ID" in *__*__*) die "EXPECTED_ORG_ID is still the placeholder '$EXPECTED_ORG_ID'; set it to the org ID of '$TARGET_ORG'." ;; esac
ORG_JSON=$(sf org display --target-org "$TARGET_ORG" --json 2>/dev/null) || die "Cannot reach org '$TARGET_ORG'. Authenticate first (sf org login web -a $TARGET_ORG)."
ORG_ID=$(printf '%s' "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("id",""))')
if [ -z "$EXPECTED_ORG_ID" ]; then
  log "WARN: EXPECTED_ORG_ID is not set, so the org ID is not checked."
elif [ "${ORG_ID:0:15}" != "${EXPECTED_ORG_ID:0:15}" ]; then
  die "Org '$TARGET_ORG' is $ORG_ID, not the expected $EXPECTED_ORG_ID. Nothing was changed."
fi
CLI_USERNAME=$(printf '%s' "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("username",""))')
ADMIN_USERNAME="${ADMIN_USERNAME:-$CLI_USERNAME}"
[ -n "$ADMIN_USERNAME" ] || die "Could not determine admin username."

ADMIN_ID=$(soql_first "SELECT Id FROM User WHERE Username = '$(soql_escape "$ADMIN_USERNAME")' AND IsActive = true" Id) || ADMIN_ID=""
[ -n "$ADMIN_ID" ] || die "Active admin user $ADMIN_USERNAME not found."
ADMIN_EMAIL=$(soql_first "SELECT Email FROM User WHERE Id = '$ADMIN_ID'" Email)
ADMIN_TZ=$(soql_first "SELECT TimeZoneSidKey FROM User WHERE Id = '$ADMIN_ID'" TimeZoneSidKey)
log "== Admin / live specialist: $ADMIN_USERNAME ($ADMIN_ID)"

AGENT_USERNAME="${AGENT_USERNAME:-nwagent.${ADMIN_USERNAME}}"

# 1. Agent user
log "== Agent user: $AGENT_USERNAME"
PROFILE_ID=$(soql_first "SELECT Id FROM Profile WHERE Name = '$AGENT_PROFILE_NAME' AND UserLicense.Name = 'Einstein Agent'" Id) || PROFILE_ID=""
[ -n "$PROFILE_ID" ] || die "Profile '$AGENT_PROFILE_NAME' (license Einstein Agent) not found. Is Agentforce enabled?"

AGENT_ID=$(soql_first "SELECT Id FROM User WHERE Username = '$(soql_escape "$AGENT_USERNAME")'" Id) || AGENT_ID=""
if [ -z "$AGENT_ID" ]; then
  NICKNAME="nwagent$(date +%s)"
  AGENT_ID=$(create_record User "Username='$AGENT_USERNAME' LastName='$AGENT_LASTNAME' FirstName='Northwind' Email='$ADMIN_EMAIL' Alias='$AGENT_ALIAS' CommunityNickname='$NICKNAME' ProfileId='$PROFILE_ID' TimeZoneSidKey='${ADMIN_TZ:-America/Los_Angeles}' LocaleSidKey='en_US' LanguageLocaleKey='en_US' EmailEncodingKey='UTF-8'") \
    || die "Failed to create agent user $AGENT_USERNAME (Einstein Agent licenses exhausted, or username taken in another org - set AGENT_USERNAME)."
  done_log "Created agent user $AGENT_USERNAME ($AGENT_ID)"
else
  IS_ACTIVE=$(soql_first "SELECT IsActive FROM User WHERE Id = '$AGENT_ID'" IsActive)
  CUR_PROFILE=$(soql_first "SELECT Profile.Name FROM User WHERE Id = '$AGENT_ID'" Profile.Name)
  log "  Agent user already exists ($AGENT_ID, profile: $CUR_PROFILE, active: $IS_ACTIVE)"
  [ "$CUR_PROFILE" = "$AGENT_PROFILE_NAME" ] || warn "Existing user $AGENT_USERNAME has profile '$CUR_PROFILE', expected '$AGENT_PROFILE_NAME'."
  if [ "$IS_ACTIVE" != "True" ] && [ "$IS_ACTIVE" != "true" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "  [dry-run] would reactivate $AGENT_USERNAME"
    else
      sf data update record --target-org "$TARGET_ORG" --sobject User --record-id "$AGENT_ID" --values "IsActive=true" --json >/dev/null 2>&1 \
        && log "  Reactivated agent user" || warn "Could not reactivate agent user $AGENT_USERNAME."
    fi
  fi
fi

if [ "$AGENT_ID" != "DRYRUN" ]; then
  for psl in "${AGENT_PSLS[@]}"; do ensure_psl "$AGENT_ID" "$psl" 1; done
  PS_LIST=("${AGENT_PERMSETS[@]}")
  if [ -n "${EXTRA_AGENT_PERMSETS:-}" ]; then
    for p in $(printf '%s' "$EXTRA_AGENT_PERMSETS" | tr ',' ' '); do
      PS_LIST+=("$p")
    done
  fi
  for ps in "${PS_LIST[@]}"; do ensure_permset "$AGENT_ID" "$ps"; done
fi

# 2 and 3. Live support specialist and queue membership
if [ "$SKIP_ADMIN" != "1" ]; then
  log "== Live-support specialist permissions for $ADMIN_USERNAME"
  for psl in "${ADMIN_REQUIRED_PSLS[@]}"; do ensure_psl "$ADMIN_ID" "$psl" 1; done
  for psl in "${ADMIN_OPTIONAL_PSLS[@]}"; do ensure_psl "$ADMIN_ID" "$psl" 0; done
  for ps in "${ADMIN_PERMSETS[@]}"; do ensure_permset "$ADMIN_ID" "$ps"; done

  log "== Queue membership: $QUEUE_DEVELOPER_NAME"
  QUEUE_ID=$(soql_first "SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = '$QUEUE_DEVELOPER_NAME'" Id) || QUEUE_ID=""
  if [ -z "$QUEUE_ID" ]; then
    warn "Queue $QUEUE_DEVELOPER_NAME not found (deploy force-app/main/default/queues first, then re-run)."
  else
    MEMBER_ID=$(soql_first "SELECT Id FROM GroupMember WHERE GroupId = '$QUEUE_ID' AND UserOrGroupId = '$ADMIN_ID'" Id) || MEMBER_ID=""
    if [ -n "$MEMBER_ID" ]; then
      log "  $ADMIN_USERNAME is already a member of $QUEUE_DEVELOPER_NAME"
    elif create_record GroupMember "GroupId='$QUEUE_ID' UserOrGroupId='$ADMIN_ID'" >/dev/null; then
      done_log "Added $ADMIN_USERNAME to $QUEUE_DEVELOPER_NAME"
    else
      warn "Could not add $ADMIN_USERNAME to queue $QUEUE_DEVELOPER_NAME."
    fi
  fi
fi

log ""
log "== Done. Agent user: $AGENT_USERNAME"
log "   Replace __AGENT_USER_USERNAME__ (default_agent_user) in force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent with this value before publishing (runbook step 10)."
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  log "== ${#WARNINGS[@]} warning(s):"
  for w in "${WARNINGS[@]}"; do log "   - $w"; done
fi
printf '%s\n' "$AGENT_USERNAME"
