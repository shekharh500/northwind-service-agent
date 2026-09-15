#!/usr/bin/env bash
#
# create-portal.sh
#
# Creates the "Northwind Support" Experience Cloud site from the Build Your Own (LWR)
# template, activates it, adds the Enhanced Chat component and publishes it.
#
# Usage: scripts/create-portal.sh <step> [<step> ...]
#
#   preflight  Check the org ID, Digital Experiences and the site template (read-only)
#   create     Create the site with guest access set from AUTH_TYPE, then wait for the
#              Network record
#   retrieve   Retrieve the site's DigitalExperienceBundle, DigitalExperienceConfig, Network
#              and CustomSite metadata into $WORK_DIR/retrieve
#   activate   Set the Network status to Live (check-only validation, then deploy)
#   messaging  Add the embeddedMessaging component for ESD_NAME to the footer of every theme
#              layout and set the site authentication type to AUTH_TYPE. This does not
#              publish the site; run publish after it.
#   publish    Publish the site and check that the guest URL returns HTTP 200
#   status     Show the Network record, Site records and chat deployment (read-only)
#   all        preflight, create, retrieve, activate, messaging, publish
#
# With DRY_RUN=1, commands that change the org are printed instead of run. Queries, retrieves
# into $WORK_DIR and check-only validations still run. Steps that need Digital Experiences or
# the site are skipped when those are missing.
#
# Environment (defaults shown):
#   ORG_ALIAS=northwind-dev   EXPECTED_ORG_ID=   (empty: the org ID is not checked)
#   SITE_NAME="Northwind Support"       URL_PREFIX=support
#   TEMPLATE_NAME="Build Your Own (LWR)"
#   AUTH_TYPE=AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED   (AUTHENTICATED for members only)
#   SITE_DOMAIN=https://__MY_DOMAIN__.my.site.com   placeholder; messaging, publish and all
#                   stop until it is set to the org's site domain
#   ESD_NAME=NW_Portal_Chat
#   SCRT_URL        defaults to the instance URL on .my.salesforce-scrt.com
#   SITE_ENDPOINT   defaults to SITE_DOMAIN plus the path of the ESW_<ESD_NAME>_* site
#   IS_EXP_SITE_AUTH_MODE=false   HIDE_CHAT_BUTTON_ON_LOAD=Default   CLIENT_VERSION=WebV2
#   WORK_DIR=$TMPDIR/nw-portal-work   POLL_SECONDS=15   POLL_MAX=60
#
# Nothing is written under force-app/. Retrieved and edited metadata stays in $WORK_DIR.

set -euo pipefail

ORG_ALIAS="${ORG_ALIAS:-northwind-dev}"
EXPECTED_ORG_ID="${EXPECTED_ORG_ID:-}"
SITE_NAME="${SITE_NAME:-Northwind Support}"
URL_PREFIX="${URL_PREFIX:-support}"
TEMPLATE_NAME="${TEMPLATE_NAME:-Build Your Own (LWR)}"
AUTH_TYPE="${AUTH_TYPE:-AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED}"
SITE_DESCRIPTION="${SITE_DESCRIPTION:-Northwind Home customer support portal with the Northwind Service Agent (Enhanced Chat).}"
SITE_DOMAIN="${SITE_DOMAIN:-https://__MY_DOMAIN__.my.site.com}"
ESD_NAME="${ESD_NAME:-NW_Portal_Chat}"
SCRT_URL="${SCRT_URL:-}"
SITE_ENDPOINT="${SITE_ENDPOINT:-}"
IS_EXP_SITE_AUTH_MODE="${IS_EXP_SITE_AUTH_MODE:-false}"
HIDE_CHAT_BUTTON_ON_LOAD="${HIDE_CHAT_BUTTON_ON_LOAD:-Default}"
CLIENT_VERSION="${CLIENT_VERSION:-WebV2}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/nw-portal-work}"
POLL_SECONDS="${POLL_SECONDS:-15}"
POLL_MAX="${POLL_MAX:-60}"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '[create-portal] %s\n' "$*" >&2; }
die()  { printf '[create-portal] ERROR: %s\n' "$*" >&2; exit 1; }

# Runs a command that changes the org, or prints it when DRY_RUN=1.
mutate() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[create-portal] DRY_RUN would run:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required on PATH"; }

# json_get <json> <python expression on d>; prints an empty string if the path is missing
json_get() {
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

soql() { # soql <query>: prints the JSON result and never fails
  sf data query -o "$ORG_ALIAS" -q "$1" --json 2>/dev/null || true
}

# sf_json <sf args...>: runs `sf <args> --json` with stdout in SF_OUT and stderr in SF_ERR,
# and returns the sf exit code. Keep the two apart; the CLI writes update notices to stderr.
sf_json() {
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/create-portal-err.XXXXXX")"
  SF_OUT="$(sf "$@" --json 2>"$errf")" || rc=$?
  SF_ERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  return "$rc"
}

soql_first() { # soql_first <query> <field>
  local out
  out="$(soql "$1")"
  json_get "$out" "(d['result']['records'] or [{}])[0].get('$2')"
}

sq() { printf "%s" "$1" | sed "s/'/\\\\'/g"; } # escape single quotes for SOQL literals

has_placeholder() { case "$1" in *__*__*) return 0 ;; *) return 1 ;; esac; } # a __NAME__ value from the repository

# SITE_DOMAIN defaults to a placeholder. Steps that build or request site URLs stop until it is set.
require_site_domain() {
  if [ -z "$SITE_DOMAIN" ] || has_placeholder "$SITE_DOMAIN"; then
    die "SITE_DOMAIN is '$SITE_DOMAIN'. Set it to the org's site domain, https://<My Domain name>.my.site.com (see config/org-values.example.env)"
  fi
}

guard_org() {
  local out id
  has_placeholder "$EXPECTED_ORG_ID" && die "EXPECTED_ORG_ID is still the placeholder '$EXPECTED_ORG_ID'; set it to the org ID of '$ORG_ALIAS'"
  out="$(sf org display -o "$ORG_ALIAS" --json 2>/dev/null || true)"
  id="$(json_get "$out" "d['result']['id']")"
  [ -n "$id" ] || die "cannot read org '$ORG_ALIAS' (sf org display failed). Log in with 'sf org login web -a $ORG_ALIAS' or set ORG_ALIAS"
  if [ -z "$EXPECTED_ORG_ID" ]; then
    [ -n "${ORG_ID_WARNED:-}" ] || { log "WARNING: EXPECTED_ORG_ID is not set, so the org ID is not checked"; ORG_ID_WARNED=1; }
  fi
  [ -z "$EXPECTED_ORG_ID" ] || [ "${id:0:15}" = "${EXPECTED_ORG_ID:0:15}" ] || die "org id $id != expected $EXPECTED_ORG_ID; refusing to touch this org"
  INSTANCE_URL="$(json_get "$out" "d['result']['instanceUrl']")"
  log "org guard ok: $ORG_ALIAS is $id ($INSTANCE_URL)"
}

network_json() {
  soql "SELECT Id, Name, Status, UrlPathPrefix FROM Network WHERE Name = '$(sq "$SITE_NAME")'"
}

network_field() { json_get "$(network_json)" "(d['result']['records'] or [{}])[0].get('$1')"; }

digital_experiences_enabled() {
  # Until Digital Experiences is enabled, querying Network fails with INVALID_TYPE.
  local out name
  out="$(sf data query -o "$ORG_ALIAS" -q "SELECT Id FROM Network LIMIT 1" --json 2>/dev/null || true)"
  [ "$(json_get "$out" "d.get('status')")" = "0" ] && return 0
  name="$(json_get "$out" "d.get('name')")"
  [ "$name" = "INVALID_TYPE" ] || log "WARNING: Network probe failed for a reason other than INVALID_TYPE (${name:-no JSON output}): $(json_get "$out" "d.get('message')")"
  return 1
}

# require_site <step>: returns 0 if the site exists. If it doesn't, returns 1 under DRY_RUN
# so the caller can skip the step, and exits otherwise.
require_site() {
  [ -n "$(network_field Id)" ] && return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: site '$SITE_NAME' does not exist yet; '$1' would run once create has completed"
    return 1
  fi
  die "site '$SITE_NAME' does not exist; run create first"
}

poll_background_operation() { # poll_background_operation <jobId> <label>
  local job="$1" label="$2" i status err
  [ -n "$job" ] || die "$label: no jobId returned"
  for ((i = 1; i <= POLL_MAX; i++)); do
    status="$(soql_first "SELECT Id, Status, Error FROM BackgroundOperation WHERE Id = '$job'" Status)"
    case "$status" in
      Complete) log "$label: BackgroundOperation $job Complete"; return 0 ;;
      Error|Canceled)
        err="$(soql_first "SELECT Id, Status, Error FROM BackgroundOperation WHERE Id = '$job'" Error)"
        die "$label: BackgroundOperation $job ended with $status: $err" ;;
      *) log "$label: [$i/$POLL_MAX] status='${status:-<not visible yet>}', waiting ${POLL_SECONDS}s" ;;
    esac
    sleep "$POLL_SECONDS"
  done
  die "$label: BackgroundOperation $job did not complete in $((POLL_MAX * POLL_SECONDS))s"
}

step_preflight() {
  need sf; need python3; need curl
  guard_org
  if ! digital_experiences_enabled; then
    local msg="Digital Experiences is NOT enabled (Network sObject unavailable). Deploy force-app/main/default/settings/Communities.settings-meta.xml or enable it in Setup > Digital Experiences > Settings first."
    [ "$DRY_RUN" = "1" ] || die "$msg"
    log "DRY_RUN: $msg"
  else
    log "Digital Experiences enabled"
  fi
  local out
  out="$(sf community list template -o "$ORG_ALIAS" --json 2>/dev/null || true)"
  if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
names = [t.get("templateName") for t in d["result"]["templates"]]
sys.exit(0 if sys.argv[2] in names else 1)
' "$out" "$TEMPLATE_NAME" 2>/dev/null; then
    log "template '$TEMPLATE_NAME' available"
  else
    die "template '$TEMPLATE_NAME' not returned by 'sf community list template'"
  fi
}

step_create() {
  guard_org
  local existing job i
  if ! digital_experiences_enabled; then
    [ "$DRY_RUN" = "1" ] || die "Digital Experiences is NOT enabled; run 'preflight' for details"
    log "DRY_RUN: Digital Experiences is NOT enabled yet; the command below fails until it is"
  fi
  existing="$(network_field Id)"
  if [ -n "$existing" ]; then
    log "site '$SITE_NAME' already exists (Network $existing, status $(network_field Status)); skipping create"
    return 0
  fi
  log "creating '$SITE_NAME' from '$TEMPLATE_NAME' at /$URL_PREFIX (AuthenticationType=$AUTH_TYPE)"
  if [ "$DRY_RUN" = "1" ]; then
    mutate sf community create -o "$ORG_ALIAS" --name "$SITE_NAME" --template-name "$TEMPLATE_NAME" \
      --url-path-prefix "$URL_PREFIX" --description "$SITE_DESCRIPTION" \
      "templateParams.AuthenticationType=$AUTH_TYPE" --json
    return 0
  fi
  if ! sf_json community create -o "$ORG_ALIAS" --name "$SITE_NAME" --template-name "$TEMPLATE_NAME" \
      --url-path-prefix "$URL_PREFIX" --description "$SITE_DESCRIPTION" \
      "templateParams.AuthenticationType=$AUTH_TYPE"; then
    die "sf community create failed: $(json_get "$SF_OUT" "d.get('message')") ${SF_ERR}"
  fi
  job="$(json_get "$SF_OUT" "d['result']['jobId']")"
  log "create job: $job"
  poll_background_operation "$job" "create"
  for ((i = 1; i <= POLL_MAX; i++)); do
    existing="$(network_field Id)"
    if [ -n "$existing" ]; then
      log "Network row present: $existing (status $(network_field Status), prefix $(network_field UrlPathPrefix))"
      return 0
    fi
    log "[$i/$POLL_MAX] waiting for Network '$SITE_NAME' to appear"
    sleep "$POLL_SECONDS"
  done
  die "Network '$SITE_NAME' not visible after create completed"
}

# resolve_bundle_name <mdapi-root>: prints the DigitalExperienceBundle name (site/<DevName>)
# taken from the site's DigitalExperienceConfig.
resolve_bundle_name() {
  python3 - "$1" "$URL_PREFIX" "$SITE_NAME" <<'PY'
import glob, os, sys, xml.etree.ElementTree as ET
root, prefix, site_name = sys.argv[1:4]
ns = {"m": "http://soap.sforce.com/2006/04/metadata"}
for path in glob.glob(os.path.join(root, "digitalExperienceConfigs", "*")):
    try:
        t = ET.parse(path).getroot()
    except ET.ParseError:
        continue
    if (t.findtext("m:site/m:urlPathPrefix", default="", namespaces=ns) == prefix
            or t.findtext("m:label", default="", namespaces=ns) == site_name):
        space = t.findtext("m:space", default="", namespaces=ns)
        if space:
            print(space)
            sys.exit(0)
# Fall back to the default name for a Build Your Own (LWR) site: site/<Site_Name>1
print("[create-portal] WARNING: no DigitalExperienceConfig with urlPathPrefix '%s' found; guessing the default bundle name" % prefix, file=sys.stderr)
print("site/" + site_name.replace(" ", "_") + "1")
PY
}

mdapi_root() { # mdapi_root <dir>: prints the directory that holds package.xml
  local pkg
  pkg="$(find "$1" -name package.xml -not -path '*/node_modules/*' | head -1)"
  [ -n "$pkg" ] || die "no package.xml under $1"
  dirname "$pkg"
}

step_retrieve() {
  guard_org
  local dir="$WORK_DIR/retrieve" root bundle
  require_site retrieve || return 0
  rm -rf "$dir" "$WORK_DIR/bundle.name" "$WORK_DIR/retrieve.root"; mkdir -p "$dir"
  log "retrieving site metadata into $dir"
  sf project retrieve start -o "$ORG_ALIAS" \
    --metadata DigitalExperienceConfig --metadata DigitalExperienceBundle \
    --metadata "Network:$SITE_NAME" --metadata CustomSite \
    --target-metadata-dir "$dir" --unzip --wait 30 >/dev/null
  root="$(mdapi_root "$dir")"
  bundle="$(resolve_bundle_name "$root")"
  printf '%s\n' "$root" > "$WORK_DIR/retrieve.root"
  printf '%s\n' "$bundle" > "$WORK_DIR/bundle.name"
  log "metadata root: $root"
  log "DigitalExperienceBundle: $bundle"
  [ -d "$root/digitalExperiences/$bundle" ] || log "WARNING: $root/digitalExperiences/$bundle not found; inspect $root"
  find "$root/digitalExperiences/$bundle" -path '*sfdc_cms__themeLayout*' -name content.json 2>/dev/null | sed 's/^/[create-portal]   themeLayout: /' >&2 || true
}

step_activate() {
  guard_org
  local status dir root file
  require_site activate || return 0
  status="$(network_field Status)"
  if [ "$status" = "Live" ]; then
    log "Network already Live"
    return 0
  fi
  dir="$WORK_DIR/activate"; rm -rf "$dir"; mkdir -p "$dir"
  sf project retrieve start -o "$ORG_ALIAS" --metadata "Network:$SITE_NAME" \
    --target-metadata-dir "$dir" --unzip --wait 30 >/dev/null
  root="$(mdapi_root "$dir")"
  # '|| true' lets a missing networks/ directory reach the die below instead of exiting on pipefail.
  file="$(find "$root/networks" -name '*.network' 2>/dev/null | head -1 || true)"
  [ -n "$file" ] || die "Network metadata file not retrieved under $root/networks (is Network.Name exactly '$SITE_NAME'?); fallback: Workspaces > Administration > Settings > Activate"
  python3 - "$file" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2, n = re.subn(r"<status>[^<]*</status>", "<status>Live</status>", s, count=1)
if n == 0:
    sys.exit("no <status> element in " + p)
open(p, "w", encoding="utf-8").write(s2)
PY
  log "Network status set to Live in $file (current org status: ${status:-unknown})"
  log "check-only validation of the Network change"
  sf project deploy validate -o "$ORG_ALIAS" --metadata-dir "$root" --test-level RunLocalTests --wait 30
  mutate sf project deploy start -o "$ORG_ALIAS" --metadata-dir "$root" --wait 30
  [ "$DRY_RUN" = "1" ] || log "Network status now: $(network_field Status)"
  return 0
}

resolve_messaging_inputs() {
  local esd_json site_json
  esd_json="$(sf data query -o "$ORG_ALIAS" --use-tooling-api \
    -q "SELECT Id, DeveloperName FROM EmbeddedServiceConfig WHERE DeveloperName = '$ESD_NAME'" --json 2>/dev/null || true)"
  ESD_ID="$(json_get "$esd_json" "(d['result']['records'] or [{}])[0].get('Id')")"
  [ -n "$ESD_ID" ] || return 1
  if [ -z "$SCRT_URL" ]; then
    SCRT_URL="${INSTANCE_URL/.my.salesforce.com/.my.salesforce-scrt.com}"
  fi
  if [ -z "$SITE_ENDPOINT" ]; then
    # The deployment's site endpoint is the ESW_<deployment>_* Site record (SiteType
    # ChatterNetworkPicasso) whose UrlPathPrefix does not end in "vforcesite". '_' is a wildcard
    # in SOQL LIKE, so the exact prefix is checked again in Python.
    site_json="$(soql "SELECT Name, UrlPathPrefix, SiteType, Status FROM Site WHERE Name LIKE 'ESW_${ESD_NAME}%'")"
    local prefix
    prefix="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
want = "ESW_" + sys.argv[2] + "_"
rows = [r for r in d["result"]["records"]
        if (r.get("Name") or "").startswith(want)
        and not (r.get("UrlPathPrefix") or "").endswith("vforcesite")]
rows.sort(key=lambda r: r.get("Name") or "", reverse=True)          # newest first
rows.sort(key=lambda r: r.get("SiteType") != "ChatterNetworkPicasso")  # then Picasso sites first
if len({r.get("Name") for r in rows}) > 1:
    print("[create-portal] WARNING: several ESW sites match; using " + rows[0]["Name"], file=sys.stderr)
print(rows[0]["UrlPathPrefix"] if rows else "")
' "$site_json" "$ESD_NAME" || true)"
    [ -n "$prefix" ] || die "ESD $ESD_NAME exists but no ESW_${ESD_NAME}* Site row without the vforcesite suffix was found; set SITE_ENDPOINT explicitly (Setup > Embedded Service Deployments > $ESD_NAME > Code Snippet)"
    SITE_ENDPOINT="$SITE_DOMAIN/$prefix"
  fi
  return 0
}

step_messaging() {
  guard_org
  if ! resolve_messaging_inputs; then
    log "Embedded Service Deployment '$ESD_NAME' not found (tooling EmbeddedServiceConfig); skipping messaging placement"
    return 0
  fi
  require_site messaging || return 0
  log "ESD $ESD_NAME ($ESD_ID) scrtUrl=$SCRT_URL siteEndpoint=$SITE_ENDPOINT"

  local bundle dir root site_dir
  # Retrieve first so the bundle name comes from the org rather than an earlier run.
  step_retrieve
  bundle="$(cat "$WORK_DIR/bundle.name")"
  # Retrieve the bundle on its own so the deploy package contains nothing else.
  dir="$WORK_DIR/messaging"; rm -rf "$dir"; mkdir -p "$dir"
  sf project retrieve start -o "$ORG_ALIAS" --metadata "DigitalExperienceBundle:$bundle" \
    --target-metadata-dir "$dir" --unzip --wait 30 >/dev/null
  root="$(mdapi_root "$dir")"
  site_dir="$root/digitalExperiences/$bundle"
  [ -d "$site_dir/sfdc_cms__themeLayout" ] || die "no sfdc_cms__themeLayout under $site_dir"

  python3 - "$site_dir" "$ESD_NAME" "$SCRT_URL" "$SITE_ENDPOINT" "$IS_EXP_SITE_AUTH_MODE" \
    "$HIDE_CHAT_BUTTON_ON_LOAD" "$CLIENT_VERSION" "$AUTH_TYPE" <<'PY'
import glob, json, os, sys, uuid
site_dir, deployment, scrt, endpoint, auth_mode, hide, client, site_auth_type = sys.argv[1:9]

# Guest access on an LWR site is set by contentBody.authenticationType in
# sfdc_cms__site/<name>/content.json. A site created in Setup without "Public can access the
# site" is AUTHENTICATED, and guests never see the chat button.
for path in sorted(glob.glob(os.path.join(site_dir, "sfdc_cms__site", "*", "content.json"))):
    with open(path, encoding="utf-8") as fh:
        sdoc = json.load(fh)
    body = sdoc.get("contentBody")
    if not isinstance(body, dict) or "authenticationType" not in body:
        print(f"[create-portal]   WARNING: no contentBody.authenticationType in {path}; check 'Public can access the site' in Builder", file=sys.stderr)
        continue
    if site_auth_type and body["authenticationType"] != site_auth_type:
        print(f"[create-portal]   site authenticationType changed from {body['authenticationType']} to {site_auth_type}: {path}", file=sys.stderr)
        body["authenticationType"] = site_auth_type
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(sdoc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
DEF = "experience_messaging:embeddedMessaging"
attrs = {
    "deploymentName": deployment,
    "scrtUrl": scrt,
    "siteEndpoint": endpoint,
    "isExpSiteAuthMode": auth_mode.lower() == "true",
    "hideChatButtonOnLoad": hide,
    "clientVersion": client,
}

def find_messaging(node, hits):
    if isinstance(node, dict):
        if node.get("definition") == DEF:
            hits.append(node)
        for child in node.get("children") or []:
            find_messaging(child, hits)
    elif isinstance(node, list):
        for child in node:
            find_messaging(child, hits)
    return hits

patched = 0
for path in sorted(glob.glob(os.path.join(site_dir, "sfdc_cms__themeLayout", "*", "content.json"))):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    children = (((doc.get("contentBody") or {}).get("component") or {}).get("children")) or []
    footers = [c for c in children if isinstance(c, dict) and c.get("type") == "region" and c.get("name") == "footer"]
    if not footers:
        print(f"[create-portal]   skipped (no footer region): {path}", file=sys.stderr)
        continue
    for footer in footers:
        existing = find_messaging(footer.get("children") or [], [])
        if existing:
            for node in existing:           # update in place, keep the id
                node["attributes"] = dict(attrs)
                node.setdefault("type", "component")
            continue
        new_node = {"id": str(uuid.uuid4()), "type": "component", "definition": DEF, "attributes": dict(attrs)}
        footer.setdefault("children", [])
        section = next((c for c in footer["children"] if isinstance(c, dict)
                        and c.get("type") == "component" and c.get("definition") == "community_layout:section"), None)
        if section is None:
            footer["children"].append(new_node)
        else:
            section.setdefault("children", [])
            region = next((c for c in section["children"] if isinstance(c, dict) and c.get("type") == "region"), None)
            (region.setdefault("children", []) if region is not None else section["children"]).append(new_node)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    count = sum(len(find_messaging(f, [])) for f in footers)
    print(f"[create-portal]   patched ({count} messaging node(s) in footer): {path}", file=sys.stderr)
    patched += 1
if patched == 0:
    sys.exit("no themeLayout with a footer region was patched")
PY
  log "check-only validation of the patched DigitalExperienceBundle"
  sf project deploy validate -o "$ORG_ALIAS" --metadata-dir "$root" --test-level RunLocalTests --wait 30
  mutate sf project deploy start -o "$ORG_ALIAS" --metadata-dir "$root" --wait 30
  log "patched bundle kept at $site_dir"
}

step_publish() {
  guard_org
  need curl
  local job code="" i
  require_site publish || return 0
  if [ "$DRY_RUN" = "1" ]; then
    mutate sf community publish -o "$ORG_ALIAS" --name "$SITE_NAME" --json
    return 0
  fi
  if ! sf_json community publish -o "$ORG_ALIAS" --name "$SITE_NAME"; then
    die "sf community publish failed: $(json_get "$SF_OUT" "d.get('message')") ${SF_ERR}"
  fi
  job="$(json_get "$SF_OUT" "d['result']['jobId']")"
  log "publish job: $job url: $(json_get "$SF_OUT" "d['result']['url']")"
  poll_background_operation "$job" "publish"
  log "Network status after publish: $(network_field Status) (expected Live; if not, run 'activate' or Workspaces > Administration > Settings > Activate)"
  for ((i = 1; i <= 4; i++)); do
    code="$(curl -sL -o /dev/null -w '%{http_code}' "$SITE_DOMAIN/$URL_PREFIX/" || true)"
    log "guest smoke test $SITE_DOMAIN/$URL_PREFIX/ returned HTTP $code"
    [ "$code" = "200" ] && break
    sleep 60
  done
  [ "$code" = "200" ] || log "WARNING: guest URL did not return 200; check Network status (activate), 'Public can access the site', and publish state"
  log "note: the chat launcher mounts client-side; confirm it visually in a private browser window (curl cannot see it)"
}

step_status() {
  guard_org
  has_placeholder "$SITE_DOMAIN" && log "WARNING: SITE_DOMAIN is still $SITE_DOMAIN, so the siteEndpoint shown below is not a real URL"
  if ! digital_experiences_enabled; then log "Digital Experiences: NOT enabled"; return 0; fi
  log "Network: $(network_json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["records"])' 2>/dev/null)"
  log "Site rows: $(soql "SELECT Name, UrlPathPrefix, SiteType, Status FROM Site" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([(r["Name"], r["UrlPathPrefix"], r["SiteType"], r["Status"]) for r in d["result"]["records"]])' 2>/dev/null)"
  if resolve_messaging_inputs; then log "ESD $ESD_NAME: $ESD_ID scrtUrl=$SCRT_URL siteEndpoint=$SITE_ENDPOINT"; else log "ESD $ESD_NAME: not found"; fi
  [ -s "$WORK_DIR/retrieve.root" ] && log "last retrieve: $(cat "$WORK_DIR/retrieve.root") bundle=$(cat "$WORK_DIR/bundle.name" 2>/dev/null)"
  return 0
}

main() {
  [ "$#" -ge 1 ] || { sed -n '3,40p' "$0"; exit 2; }
  local s
  for s in "$@"; do
    case "$s" in messaging|publish|all) require_site_domain ;; esac
  done
  need sf; need python3
  mkdir -p "$WORK_DIR"
  for s in "$@"; do
    case "$s" in
      preflight) step_preflight ;;
      create)    step_create ;;
      retrieve)  step_retrieve ;;
      activate)  step_activate ;;
      messaging) step_messaging ;;
      publish)   step_publish ;;
      status)    step_status ;;
      all)       step_preflight; step_create; step_retrieve; step_activate; step_messaging; step_publish ;;
      *) die "unknown step '$s' (preflight|create|retrieve|activate|messaging|publish|status|all)" ;;
    esac
  done
}

main "$@"
