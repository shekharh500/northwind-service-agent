# Northwind Service Agent: Build Runbook

This runbook builds the Northwind Service Agent in a Salesforce org from this repository. The steps are in dependency order, and each one has a verification check and a short rollback note. Steps marked Manual are done in Setup; the linked page in `docs/manual-steps` has the full click path.

The commands take the org alias and other org-specific values from `config/org-values.local.env` (next section). The pages in `docs/manual-steps` use the alias `northwind-dev`. The reference org, where the build is complete and agent version 6 is active, is described with masked values: record IDs show their key prefix followed by X's (for example `1JDXXXXXXXXXXXXXXX`), and org-specific names appear as `<org-id>`, `<my-domain>` or `<agent-user-username>`. Where a command needs an ID from your org, it has a placeholder such as `<library-id>`. Run every command from the project root.

## Org-specific values

Values that depend on the org are either environment variables for the scripts or placeholders in the deployable files. The steps in the last column use or replace them:

| Placeholder or variable | Where it is | Value | Step |
| --- | --- | --- | --- |
| `ORG_ALIAS`, `TARGET_ORG` | Environment variables read by `scripts/create-portal.sh` (`ORG_ALIAS`), `scripts/setup-data-library.sh` and `scripts/setup-agent-user.sh` (`TARGET_ORG`); `ORG` in the commands | The CLI alias of your org | all |
| `EXPECTED_ORG_ID` | Environment variable read by all three scripts | Your org ID. When it is set, a script stops if the alias points to another org; when it is empty, the check is skipped | all |
| `__RETRIEVER_API_NAME__` | The three `NW_Doc_*` prompt templates | The retriever API name, `RETRIEVER_API_NAME` | 2 |
| `__MY_DOMAIN__` | `NW_Portal_Site_Domain` and `NW_Messaging_SCRT` (description only) in `cspTrustedSites/`, `NW_Portal_Site_Origin` and `NW_Messaging_SCRT_Origin` in `corsWhitelistOrigins/` | `MY_DOMAIN`, the host of your org URL without `.my.salesforce.com`. The site domain is `MY_DOMAIN` plus `.my.site.com` and the SCRT domain is `MY_DOMAIN` plus `.my.salesforce-scrt.com` | 7 |
| `SITE_DOMAIN` | Environment variable read by `scripts/create-portal.sh`. Its default holds `__MY_DOMAIN__`, and the `messaging`, `publish` and `all` steps stop until it is set | `https://<my-domain>.my.site.com` | 14, 15 |
| `__AGENT_USER_USERNAME__` | `default_agent_user` in `Northwind_Service_Agent.agent` | The agent username printed by `scripts/setup-agent-user.sh`, `AGENT_USER_USERNAME` | 10 |

`config/org-values.example.env` lists these variables. Before step 0, copy it to `config/org-values.local.env` (git ignores it) and set `ORG_ALIAS`, `EXPECTED_ORG_ID` and `MY_DOMAIN`. `RETRIEVER_API_NAME` and `AGENT_USER_USERNAME` are added after steps 2 and 9. To read the org ID and My Domain name of an authenticated alias:

```bash
sf org display -o <alias> --json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print("EXPECTED_ORG_ID=" + r["id"]); print("MY_DOMAIN=" + r["instanceUrl"].split("//")[1].replace(".my.salesforce.com", ""))'
```

Check for placeholders that are still in place before any deploy:

```bash
grep -rnE "__[A-Z][A-Z_]*__" force-app     # lists each file and line that still needs a value
```

## Step overview

Dependency chain: data library, then retriever name, then prompt templates; Omni-Channel settings, queue, outbound flow and agent user, then agent publish and activation; then the inbound flow, messaging channel, embedded service deployment, portal component and publish.

| # | Step | Type | Depends on |
| --- | --- | --- | --- |
| 0 | Preflight (read-only) | CLI | Data Cloud provisioning done |
| 1 | Data library: create, upload the four PDFs, wait for the retriever | CLI (changes org) | 0 |
| 2 | Retriever API name into the prompt templates | CLI read, local edit | 1 |
| 3 | Settings: Omni-Channel, Messaging, Digital Experiences | Deploy | 0 |
| 4 | Presence status, routing config, queue | Deploy | 3 |
| 5 | Outbound escalation flow `NW_Escalate_To_Live_Agent` | Deploy | 4 |
| 6 | Permission set `NW_Live_Support_Agent` | Deploy | 4 |
| 7 | CSP Trusted URLs and CORS origins | Deploy | none |
| 8 | Prompt templates, then confirm they are active | Deploy, Manual check | 2 |
| 9 | Agent user, licenses, specialist permissions, queue member | Script (changes data) | 4, 6 |
| 10 | Agent username, validate, publish, activate | CLI (changes org) | 5, 8, 9 |
| 11 | Preview smoke test | CLI | 10 |
| 12 | Inbound flow `NW_Route_Messaging_To_Agent` | Deploy, Manual check | 10 |
| 13 | Messaging channel `NW_Web_Chat`: deploy and activate | Deploy, Manual or CLI | 3, 12 |
| 14 | Embedded service deployment `NW_Portal_Chat` | Manual or Connect API | 13, site exists |
| 15 | Portal: activate, add the chat component, publish | Script (changes org) | 7, 14 |
| 16 | Service Console for the specialist | Manual | 6, 9 |
| 17 | Agent tests and end-to-end chat | CLI, browser | all |

Shell setup used by every step:

```bash
cd path/to/agentforce-service-agent
set -a; . config/org-values.local.env; set +a     # exports ORG_ALIAS, TARGET_ORG, EXPECTED_ORG_ID, MY_DOMAIN, SITE_DOMAIN and the rest
ORG=$ORG_ALIAS
```

Load the file again after you add a value to it.

General notes:

- In CLI 2.106.6, `sf project deploy validate` rejects `--test-level NoTestRun`. Use `--test-level RunLocalTests` for check-only runs; the org's local tests run and roll back. `sf project deploy start` without a test level is fine in a Developer Edition org.
- When parsing `--json` output, read stdout only (`2>/dev/null`). The CLI prints update notices on stderr, and a merged capture is not valid JSON.
- Steps 2, 7 and 10 write org-specific values into tracked files. Don't commit them to a public repository. The rollback note in each of those steps puts the placeholders back, and so does `git restore` on the changed files.
- The `sed -i ''` commands are for macOS. With GNU sed, use `sed -i`.

## 0. Preflight (read-only)

```bash
sf org display -o $ORG --json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r["id"], r["instanceUrl"])'
# expect $EXPECTED_ORG_ID and https://$MY_DOMAIN.my.salesforce.com

sf agent adl list -o $ORG --json 2>/dev/null          # must return status 0 (the data library API is available)
sf data query -o $ORG -q "SELECT Id, Name, Status FROM DataSpace"      # expect 'default'
sf data query -o $ORG -q "SELECT Id, Name, Status, UrlPathPrefix FROM Network WHERE Name = 'Northwind Support'"   # 1 row once the site exists
scripts/setup-data-library.sh preflight              # org guard, data library API, the 4 PDFs in docs/pdf
```

The `Network` query errors until Digital Experiences is enabled (step 3).

Manual: Setup > Data Cloud Setup (Data 360 Setup) shows provisioning complete. If `sf agent adl list` errors, wait for provisioning before going on.

Rollback: none.

## 1. Data library: create, upload the four PDFs, wait for the retriever

Use the PDFs in `docs/pdf`. They are generated from the Markdown in `docs/source` by `scripts/build_docs.py`; if you change the source text, rebuild the PDFs before uploading. Creating an SFDRIVE library with the enhanced index mode sets up the Data Cloud pipeline for unstructured files: data lake object, data model object, chunked search index and retriever.

Option A, script. It skips `create` if `Northwind_Home_Docs` already exists and uploads only files that are missing by name. `DRY_RUN=1` prints the commands that would change the org.

```bash
DRY_RUN=1 scripts/setup-data-library.sh all          # preview
scripts/setup-data-library.sh create upload wait     # WAIT_MINUTES defaults to 45
```

Option B, raw commands:

```bash
sf agent adl create -o $ORG --name "Northwind Home Docs" --developer-name Northwind_Home_Docs \
  --description "Northwind Home warranty, returns and refunds, Aura T200 manual and CarePlus SLA PDFs for the Northwind Service Agent." \
  --source-type sfdrive --index-mode enhanced --json

LIB_ID=$(sf agent adl list -o $ORG --json 2>/dev/null | python3 -c 'import json,sys; print(next(l["libraryId"] for l in json.load(sys.stdin)["result"]["libraries"] if l["developerName"]=="Northwind_Home_Docs"))')
echo "$LIB_ID"                                        # 1JD...

# One upload call with all 4 files; --wait polls until retrieverId is populated.
sf agent adl upload -o $ORG -i "$LIB_ID" --wait 45 --json \
  -f docs/pdf/01-warranty-policy.pdf \
  -f docs/pdf/02-returns-refunds-policy.pdf \
  -f docs/pdf/03-aura-thermostat-t200-manual.pdf \
  -f docs/pdf/04-careplus-service-plans-sla.pdf
```

The commands from here on use `LIB_ID`. After Option A, set it with the `LIB_ID=$(...)` line from Option B.

For SFDRIVE libraries `--wait` belongs on `adl upload`; on `adl create` it only applies to Knowledge libraries. If the upload times out (`UploadTimeout`), indexing carries on. Keep polling with `scripts/setup-data-library.sh wait` or the status command below.

Verify:

```bash
sf agent adl status -o $ORG -i "$LIB_ID" --include-artifacts     # READY; DATA_LAKE_OBJECT, DATA_MODEL_OBJECT, SEARCH_INDEX, RETRIEVER and INDEXING all SUCCESS
sf agent adl file list -o $ORG -i "$LIB_ID" --status indexed      # 4 files
sf agent adl get -o $ORG -i "$LIB_ID"                             # Status READY, Retriever ID present
```

Record the data lake object, data model object, search index and retriever names in the results table of `docs/TEST_PLAN.md` (section 10).

### Replacing documents in an existing library

Use this procedure when a PDF in `docs/pdf` changes after the library was loaded. Don't run a second `upload` on a library that is already READY, and don't rely on the script: it matches files by name, so it skips a changed PDF that keeps its file name. Delete the old file references, then add the new files:

```bash
sf agent adl file list -o $ORG -i "$LIB_ID" --json 2>/dev/null | python3 -c 'import json,sys; [print(f["fileId"], f["fileName"]) for f in json.load(sys.stdin)["result"]["files"]]'
sf agent adl file delete -o $ORG -i "$LIB_ID" --file-id <1Jc... ID of the old file>      # once per file being replaced
sf agent adl file list -o $ORG -i "$LIB_ID"                                                # wait until the deleted files are gone
sf agent adl file add -o $ORG -i "$LIB_ID" --path docs/pdf/01-warranty-policy.pdf       # repeat --path for each new file
sf agent adl file list -o $ORG -i "$LIB_ID" --status indexed                              # all 4 files indexed again
```

`file add` appends to the existing search index and re-indexes it without creating new Data Cloud assets, so the retriever name and the prompt templates do not change. To add a brand-new document, use `file add` on its own.

Check the file sizes afterward, because a failed delete is easy to miss. In the reference org the delete of `01-warranty-policy.pdf` reported "We couldn't delete your file. Try again." and left the old reference in place. After `file add` that reference showed the new file's size and status INDEXED, but kept its old created date (`docs/evidence/BUILD_EVIDENCE.md`, section "Documents in the data library"). Compare each `fileSize` with the local PDF:

```bash
sf agent adl file list -o $ORG -i "$LIB_ID" --json 2>/dev/null | python3 -c 'import json,sys; [print(f["fileName"], f["fileSize"], f["status"], f["createdDate"]) for f in json.load(sys.stdin)["result"]["files"]]'
ls -l docs/pdf
```

Rollback: `sf agent adl file delete` removes one file. `sf agent adl delete -o $ORG -i "$LIB_ID"` removes the whole library and the Data Cloud assets it created, and cannot be undone; read `sf agent adl delete --help` first.

## 2. Retriever API name into the prompt templates

The templates need the retriever's developer name (shape `<Label>_1Cx_<hash>`), not its record ID. In the reference org neither CLI command returned it: `sf agent adl get` and `sf agent adl status --include-artifacts` give only the retriever's ID and label (`File_Northwind_Home_Docs`), so `scripts/setup-data-library.sh resolve` finds nothing. Expect to read the name in Prompt Builder.

In the repository the three templates hold the placeholder `__RETRIEVER_API_NAME__`, 3 times per file. In the reference org the name is `File_Northwind_Home_Docs_1Cx_<suffix>`.

Read the name in Prompt Builder (Manual): open any Flex template, Insert Resource > Retrievers (or Einstein Search), pick the Northwind library retriever, and read it from the inserted merge field `{!$EinsteinSearch:<API_NAME>.results}`. Cancel without saving. See `docs/manual-steps/prompt-templates.md` section 3.

Add it to `config/org-values.local.env` as `RETRIEVER_API_NAME=<name from Prompt Builder>` and load the file again. Then apply it with the script, which edits the three templates and checks for 0 placeholders, 3 hits per file and valid XML. `apply` doesn't connect to the org.

```bash
set -a; . config/org-values.local.env; set +a
scripts/setup-data-library.sh apply
```

Or with `sed`:

```bash
sed -i '' "s/__RETRIEVER_API_NAME__/${RETRIEVER_API_NAME}/g" force-app/main/default/genAiPromptTemplates/NW_Doc_*.genAiPromptTemplate-meta.xml
```

If another CLI release returns the name (as `retriever.apiName` in `sf agent adl get`, or as the RETRIEVER artifact's `apiName` in `sf agent adl status --include-artifacts`), `scripts/setup-data-library.sh resolve apply` looks it up and applies it, as long as `RETRIEVER_API_NAME` is empty. To look it up yourself for the `sed` command above, use the Option B commands in `docs/manual-steps/prompt-templates.md` section 3.

Verify:

```bash
grep -c "__RETRIEVER_API_NAME__" force-app/main/default/genAiPromptTemplates/*.xml    # 0 each
grep -c "$RETRIEVER_API_NAME" force-app/main/default/genAiPromptTemplates/*.xml        # 3 each
for f in force-app/main/default/genAiPromptTemplates/*.xml; do xmllint --noout "$f" && echo "OK $f"; done
```

Rollback (local only, restores the placeholder): `sed -i '' "s/${RETRIEVER_API_NAME}/__RETRIEVER_API_NAME__/g" force-app/main/default/genAiPromptTemplates/NW_Doc_*.genAiPromptTemplate-meta.xml`

## 3. Settings: Omni-Channel, Messaging, Digital Experiences

`OmniChannel.settings` turns Omni-Channel on and leaves skills routing and status-based capacity off. `LiveMessage.settings` turns Messaging on, which channel activation in step 13 needs. `Communities.settings` enables Digital Experiences; this cannot be turned off again, and it can fail while Data Cloud provisioning is still running (`docs/manual-steps/experience-portal.md` section 4). `ExperienceBundle.settings` is optional and only helps with Aura sites.

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/settings/OmniChannel.settings-meta.xml \
  --source-dir force-app/main/default/settings/LiveMessage.settings-meta.xml \
  --source-dir force-app/main/default/settings/Communities.settings-meta.xml
# optional, after the above:
sf project deploy start -o $ORG --wait 30 --source-dir force-app/main/default/settings/ExperienceBundle.settings-meta.xml
```

Verify with a retrieve into a temporary folder:

```bash
rm -rf "$TMPDIR/nw-settings-check" && sf project retrieve start -o $ORG --metadata Settings:OmniChannel --metadata Settings:LiveMessage \
  --target-metadata-dir "$TMPDIR/nw-settings-check" --unzip --wait 20 >/dev/null
grep -rh "enableOmniChannel\|enableLiveMessage" "$TMPDIR/nw-settings-check"      # both true
```

Manual fallback if the Messaging setting is rejected: Setup > Messaging Settings > turn on the Messaging toggle (`escalation-and-chat.md` 5.1).

Rollback: redeploy Messaging as `false`, only while no channel is active. Digital Experiences stays on.

## 4. Presence status, queue routing config, queue

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/servicePresenceStatuses \
  --source-dir force-app/main/default/queueRoutingConfigs \
  --source-dir force-app/main/default/queues
```

Verify:

```bash
sf data query -o $ORG -q "SELECT Id, DeveloperName FROM ServicePresenceStatus WHERE DeveloperName='NW_Available_Messaging'"
sf data query -o $ORG -q "SELECT Id, DeveloperName FROM QueueRoutingConfig WHERE DeveloperName='NW_Messaging_Routing'"
sf data query -o $ORG -q "SELECT Id, DeveloperName, QueueRoutingConfigId FROM Group WHERE Type='Queue' AND DeveloperName='NW_Live_Support'"   # QueueRoutingConfigId non-null
sf data query -o $ORG -q "SELECT SobjectType FROM QueueSobject WHERE Queue.DeveloperName='NW_Live_Support'"                                  # MessagingSession
```

Rollback: delete the queue, routing configuration and presence status in Setup, in that order. Redeploying the queue later can drop its members, so re-run step 9 afterward.

## 5. Outbound escalation flow `NW_Escalate_To_Live_Agent`

The agent's `connection messaging` and `connection customer_web_client` blocks name `flow://NW_Escalate_To_Live_Agent`, so this flow must be active before the agent is published. The flow finds the `NW_Live_Support` queue and routes the messaging session to it, where an escalated chat waits for the next available specialist. Don't deploy `NW_Route_Messaging_To_Agent` yet; that is step 12.

```bash
sf project deploy start -o $ORG --wait 30 --source-dir force-app/main/default/flows/NW_Escalate_To_Live_Agent.flow-meta.xml
```

Verify:

```bash
sf data query -o $ORG -q "SELECT ApiName, ActiveVersionId, ProcessType FROM FlowDefinitionView WHERE ApiName='NW_Escalate_To_Live_Agent'"   # ActiveVersionId non-null, RoutingFlow
```

Rollback: Setup > Flows > NW Escalate To Live Agent > Deactivate. Escalations fail until it is active again.

## 6. Permission set `NW_Live_Support_Agent`

```bash
sf project deploy start -o $ORG --wait 30 --source-dir force-app/main/default/permissionsets/NW_Live_Support_Agent.permissionset-meta.xml
```

Verify: `sf data query -o $ORG -q "SELECT Id, Name, Label FROM PermissionSet WHERE Name='NW_Live_Support_Agent'"`

Rollback: remove the assignments, then delete the permission set in Setup.

Steps 3 to 6 can also go in one `sf project deploy start` with all of the `--source-dir` flags above. These components, together with the inbound flow and the channel, passed a check-only validation before the first deploy (deploy ID `0AfXXXXXXXXXXXXXXX`).

## 7. CSP Trusted URLs and CORS origins

The four files hold `__MY_DOMAIN__`. Replace it with your My Domain name first:

```bash
sed -i '' "s/__MY_DOMAIN__/${MY_DOMAIN}/g" \
  force-app/main/default/cspTrustedSites/*.cspTrustedSite-meta.xml \
  force-app/main/default/corsWhitelistOrigins/*.corsWhitelistOrigin-meta.xml
grep -rn "__MY_DOMAIN__" force-app/main/default/cspTrustedSites force-app/main/default/corsWhitelistOrigins   # no output
grep -rh "endpointUrl\|urlPattern" force-app/main/default/cspTrustedSites force-app/main/default/corsWhitelistOrigins
```

The last command shows `https://*.salesforce-scrt.com`, your site domain and your SCRT domain. Then deploy:

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/cspTrustedSites \
  --source-dir force-app/main/default/corsWhitelistOrigins
```

Verify:

```bash
sf data query -o $ORG -q "SELECT DeveloperName, EndpointUrl, Context, IsActive FROM CspTrustedSite WHERE DeveloperName LIKE 'NW_%'"   # 2 rows
sf data query -o $ORG -q "SELECT DeveloperName, UrlPattern FROM CorsWhitelistEntry"                                                   # 2 rows
```

Rollback: delete the `NW_` entries under Setup > Trusted URLs and Setup > CORS. To restore the placeholder locally: `sed -i '' "s/${MY_DOMAIN}/__MY_DOMAIN__/g" force-app/main/default/cspTrustedSites/*.xml force-app/main/default/corsWhitelistOrigins/*.xml`

## 8. Prompt templates

Needs step 2. With the placeholder still in place, or before the retriever exists, the deploy fails with "cannot describe data provider".

```bash
sf project deploy validate -o $ORG --source-dir force-app/main/default/genAiPromptTemplates --test-level RunLocalTests --wait 15
sf project deploy start    -o $ORG --source-dir force-app/main/default/genAiPromptTemplates --wait 15
```

Verify:

```bash
sf org list metadata --metadata-type GenAiPromptTemplate -o $ORG --json 2>/dev/null | grep -E '"fullName": "NW_Doc_'     # 3 names
rm -rf "$TMPDIR/nw-gapt-check" && sf project retrieve start -o $ORG --target-metadata-dir "$TMPDIR/nw-gapt-check" --unzip \
  -m "GenAiPromptTemplate:NW_Doc_Answer_Question" -m "GenAiPromptTemplate:NW_Doc_Summarize" -m "GenAiPromptTemplate:NW_Doc_Extract_Details"
grep -rh "activeVersionIdentifier" "$TMPDIR/nw-gapt-check"     # the 3 pinned _1 values listed in prompt-templates.md section 1
```

Manual (required): in Setup > Prompt Builder, check that all three `NW_Doc_*` templates are active on version 1, and activate any that are not. Then preview each one with the inputs in `docs/manual-steps/prompt-templates.md` section 6. For example, `NW_Doc_Answer_Question` with "What is the price of the Halo Video Doorbell?" must return exactly `I couldn't find that in the Northwind Home documentation.` If Prompt Builder flags the model as unavailable, pick another model, Save As New Version, activate and retrieve (section 5 of the same page).

Rollback: deactivate the templates in Prompt Builder. Published versions can't be edited; a change needs a `_2` version (section 5).

## 9. Agent user, licenses, specialist permissions, queue membership

`scripts/setup-agent-user.sh` does the following, and skips anything that already exists:

- Creates the Einstein Agent user (profile Einstein Agent User; in the reference org `<agent-user-username>`) with permission set licenses `AgentforceServiceAgentUserPsl` and `GenieDataPlatformStarterPsl` and permission sets `AgentforceServiceAgentUser` and `GenieUserEnhancedSecurity`.
- Gives the admin, who acts as the live specialist, `ServiceUserPsl`, `EmbeddedServiceMessagingUserPsl`, `LiveMessageUserPsl` where a seat is available, and `NW_Live_Support_Agent`.
- Adds the admin to queue `NW_Live_Support`.

```bash
DRY_RUN=1 scripts/setup-agent-user.sh $ORG            # preview, no writes
AGENT_USER_USERNAME=$(scripts/setup-agent-user.sh $ORG | tail -1)
echo "$AGENT_USER_USERNAME"                           # add to config/org-values.local.env as AGENT_USER_USERNAME=...
```

The default username is `nwagent.` followed by the admin's username. Set `AGENT_USERNAME` to choose another one.

Verify:

```bash
sf data query -o $ORG -q "SELECT Username, IsActive, Profile.Name FROM User WHERE Username='$AGENT_USER_USERNAME'"
sf data query -o $ORG -q "SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username='$AGENT_USER_USERNAME'"          # AgentforceServiceAgentUser, GenieUserEnhancedSecurity
sf data query -o $ORG -q "SELECT Assignee.Username FROM PermissionSetAssignment WHERE PermissionSet.Name='NW_Live_Support_Agent'" # admin
sf data query -o $ORG -q "SELECT UserOrGroupId FROM GroupMember WHERE Group.DeveloperName='NW_Live_Support'"                     # admin user ID
```

If live answers later come back as "couldn't find" while Prompt Builder previews work, the agent user is probably missing data space access or a prompt template permission. Add `default` data space access in Setup (`docs/manual-steps/experience-portal.md` section 8; there is no API for it) and check `EinsteinGPTPromptTemplateUser` (`docs/manual-steps/prompt-templates.md` section 6), then test again. In the reference org the agent user answers with only `AgentforceServiceAgentUser` and `GenieUserEnhancedSecurity` assigned.

Rollback: deactivate the agent user in Setup > Users (users can't be deleted) and remove the admin's permission set and queue membership.

## 10. Agent: set the agent user, validate, publish, activate

Needs steps 5 (active outbound flow), 8 (active templates) and 9 (agent user).

The published agent has a router, `agent_router`, and six subagents, defined in `Northwind_Service_Agent.agent`. On every turn the router clears the per-turn state and sends the message to `document_qa`, `document_summary`, `detail_finder`, `escalation`, `off_topic` or `ambiguous_question`. The three document subagents always search. Before the search the model has one job, to call `set_search_query`, which saves the customer's message as a self-contained query (it can also hand the message to another subagent). The subagent then runs its prompt template with that query (`run @actions.NW_Doc_*`), stores the response and has the model answer from that response alone. `escalation` records a one-sentence summary with `record_handoff_summary`, then calls `@utils.escalate`, which routes through `NW_Escalate_To_Live_Agent`. The full design is in `docs/manual-steps/agent.md` section 1. In the reference org, version 6 is active.

In the repository, `default_agent_user` in the `.agent` file is the placeholder `__AGENT_USER_USERNAME__`. Replace it with the username from step 9, then validate, publish and activate:

```bash
sed -i '' "s/__AGENT_USER_USERNAME__/${AGENT_USER_USERNAME}/" force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent
grep -n "default_agent_user" force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent   # shows the agent username, not the placeholder
sf agent validate authoring-bundle --api-name Northwind_Service_Agent -o $ORG --json 2>/dev/null                 # success true
sf agent publish authoring-bundle --api-name Northwind_Service_Agent -o $ORG --skip-retrieve --json 2>/dev/null   # returns botId / botVersionId
sf agent activate --api-name Northwind_Service_Agent -o $ORG --json 2>/dev/null                                    # --json without --version activates the latest version
```

`--skip-retrieve` stops publish from writing Bot, GenAiPlugin, GenAiFunction and Agent folders into `force-app`.

Verify:

```bash
sf data query -o $ORG -q "SELECT Id, DeveloperName FROM BotDefinition WHERE DeveloperName='Northwind_Service_Agent'"
sf data query -o $ORG -q "SELECT Id, VersionNumber, Status FROM BotVersion WHERE BotDefinition.DeveloperName='Northwind_Service_Agent' ORDER BY VersionNumber"   # latest Active
sf org list metadata --metadata-type GenAiPlannerBundle -o $ORG --json 2>/dev/null | grep -i northwind
```

Then retrieve that GenAiPlannerBundle into `$TMPDIR` and check `outboundRouteName` (`docs/manual-steps/agent.md` section 7): both the Messaging and CustomerWebClient surfaces must point to `NW_Escalate_To_Live_Agent`.

If publish fails (`docs/manual-steps/agent.md` section 10): template not found means step 8 is incomplete. `ERROR_HTTP_404` on the route means the step 5 flow is not active; if it is, try the bare route name `"NW_Escalate_To_Live_Agent"` in both connection blocks. An error on `customer_web_client` can be cleared by removing that block. A user error points back to step 9.

Rollback: `sf agent deactivate --api-name Northwind_Service_Agent -o $ORG --json`. To restore the placeholder locally: `sed -i '' "s/${AGENT_USER_USERNAME}/__AGENT_USER_USERNAME__/" force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent`

## 11. Preview smoke test

Run this before any channel work.

```bash
SID=$(sf agent preview start --api-name Northwind_Service_Agent -o $ORG --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["sessionId"])')
sf agent preview send --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG -u "If I register my Aura thermostat within 30 days, how long is my warranty?"
sf agent preview send --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG -u "Summarize the returns and refunds policy"
sf agent preview send --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG -u "List every Aura T200 error code and what it means"
sf agent preview end  --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG
sf agent trace read -s "$SID" -f detail -d routing       # document_qa, document_summary, detail_finder
sf agent trace read -s "$SID" -f detail -d actions       # one or more NW_Doc_* calls per turn, with the rewritten query as input
```

Expected: 36 months (standard 24) with the warranty policy cited; a sectioned returns summary; error codes E1 to E6. Each of the three turns must show a `NW_Doc_*` call in the actions trace. If one doesn't, check the active version and see `docs/manual-steps/agent.md` section 10. `sf agent trace read -s "$SID" -f raw` also shows the `set_search_query` calls and the `search_query` values. The full list of checks is in `docs/manual-steps/agent.md` section 9. A preview session has no messaging session, so an escalation there returns an Escalate message with no text and no trace, and any later send in that session fails. Test the real handoff in step 17.

Rollback: none.

## 12. Inbound flow `NW_Route_Messaging_To_Agent`

Deploy only after step 10. The flow refers to the agent by name, and a reference to an agent that doesn't exist yet still deploys, but every chat then goes to the fallback queue.

```bash
sf project deploy start -o $ORG --wait 30 --source-dir force-app/main/default/flows/NW_Route_Messaging_To_Agent.flow-meta.xml
sf data query -o $ORG -q "SELECT ApiName, ActiveVersionId FROM FlowDefinitionView WHERE ApiName='NW_Route_Messaging_To_Agent'"   # ActiveVersionId non-null
```

Manual (required check): Setup > Flows > NW Route Messaging To Agent > active version > element Route To Northwind Service Agent. The agent field must show Northwind Service Agent. If it is blank, select the agent, Save As New Version and activate (`escalation-and-chat.md` 4.4).

Rollback: deactivate the channel (step 13) first, then the flow.

## 13. Messaging channel `NW_Web_Chat`: deploy and activate

Needs steps 3 (Messaging on), 4 (queue) and 12 (active inbound flow).

```bash
sf project deploy start -o $ORG --wait 30 --source-dir force-app/main/default/messagingChannels/NW_Web_Chat.messagingChannel-meta.xml
sf data query -o $ORG -q "SELECT DeveloperName, MessageType, RoutingType, SessionHandlerId, FallbackQueueId, IsActive FROM MessagingChannel WHERE DeveloperName='NW_Web_Chat'"
# SessionHandlerId 300..., FallbackQueueId 00G..., IsActive false until activated
```

Activate in Setup (Manual, recommended because it includes accepting the Enhanced Chat terms): Setup > Messaging Settings > Northwind Web Chat. Check the Omni-Channel routing (flow NW Route Messaging To Agent, fallback queue Northwind Live Support), then click Activate (`escalation-and-chat.md` 5.2).

CLI alternative, a direct data update:

```bash
sf data update record -o $ORG --sobject MessagingChannel --where "DeveloperName='NW_Web_Chat'" --values "IsActive=true"
```

Verify: run the MessagingChannel query again; `IsActive` is true.

Rollback: Deactivate on the same Setup page.

## 14. Embedded service deployment `NW_Portal_Chat`

Needs step 13 and an existing site. Web deployments can't be created through the Metadata API (`escalation-and-chat.md` section 6).

Option A, Setup (Manual, recommended): Setup > Embedded Service Deployments > New Deployment > Messaging for In-App and Web > Web. Name `NW Portal Chat`, API name `NW_Portal_Chat`, domain `<my-domain>.my.site.com` with your My Domain name (choose the Experience Cloud site Northwind Support if offered), messaging channel Northwind Web Chat. Save, then Publish; publishing can take up to 10 minutes.

Option B, Connect API. Run it once only; it is not idempotent.

```bash
CHAN_ID=$(sf data query -o $ORG --json -q "SELECT Id FROM MessagingChannel WHERE DeveloperName='NW_Web_Chat'" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['Id'])")
sf api request rest "/services/data/v67.0/connect/embeddedmessaging/deployment/setup" -X POST -o $ORG \
  --body "{\"name\":\"NW_Portal_Chat\",\"masterLabel\":\"NW Portal Chat\",\"deploymentType\":\"Web\",\"clientVersion\":\"WebV2\",\"hostDomain\":\"${MY_DOMAIN}.my.site.com\",\"messagingChannelId\":\"${CHAN_ID}\"}"
```

Verify:

```bash
sf data query -o $ORG --use-tooling-api -q "SELECT Id, DeveloperName, DeploymentType, IsEnabled, ClientVersion FROM EmbeddedServiceConfig WHERE DeveloperName='NW_Portal_Chat'"
sf data query -o $ORG -q "SELECT Name, UrlPathPrefix, SiteType, Status FROM Site WHERE Name LIKE 'ESW_NW_Portal_Chat%'"   # auto-generated ESW sites
```

Guest chat comes from the channel's `authMode` of `UnAuth`. The deployment's `AreGuestUsersAllowed` flag is not a prerequisite.

Rollback: remove the portal component first (step 15), then delete the deployment in Setup > Embedded Service Deployments.

## 15. Portal: activate the site, add the chat component, publish

The site is Northwind Support: Build Your Own (LWR), path `/support`, authentication type `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED`. `create` skips if the site already exists. The script reads `ORG_ALIAS`, `EXPECTED_ORG_ID` and `SITE_DOMAIN` from the environment; `messaging`, `publish` and `all` stop while `SITE_DOMAIN` still holds `__MY_DOMAIN__`.

```bash
echo "$ORG_ALIAS $SITE_DOMAIN"                            # your alias and https://<my-domain>.my.site.com
scripts/create-portal.sh status                           # read-only
DRY_RUN=1 scripts/create-portal.sh all                    # prints the commands that would change the org
scripts/create-portal.sh preflight create retrieve activate    # activate sets the Network status to Live and sends the site welcome email to members
scripts/create-portal.sh messaging                        # needs NW_Portal_Chat (step 14); adds experience_messaging:embeddedMessaging to the theme footers; does not publish
scripts/create-portal.sh publish                          # publishes, waits for the job, checks that /support/ returns HTTP 200
```

Verify:

```bash
sf data query -o $ORG -q "SELECT Id, Name, Status FROM Network WHERE Name='Northwind Support'"      # Status Live
curl -s -o /dev/null -w '%{http_code}\n' "$SITE_DOMAIN/support/"   # 200
```

Manual: open `$SITE_DOMAIN/support/` in a private window. The chat launcher shows at the bottom right, the agent's welcome message appears when the chat opens, and the browser console has no CSP or CORS errors. If the script route is rejected, use the click paths instead: Workspaces > Administration > Settings > Activate, then in Builder drag Embedded Messaging into the theme footer, set Deployment to `NW_Portal_Chat` and Publish (`experience-portal.md` 5.2 and 6.3).

Home page content and site title: the page text is kept in `portal/home/home.html` and applied with `scripts/update-portal-home.py`, which edits only the home view of a retrieved site bundle. Deploy that single component rather than the whole bundle, then publish again. The retrieve, validate and deploy commands are in `docs/manual-steps/experience-portal.md` section 5.3. The site title and meta description are in `portal/site/mainAppPage.content.json`. In the reference org the current `home.html` was deployed and the site published on September 15, 2026.

Rollback: Workspaces > Administration > Settings > Deactivate. To remove only the chat, delete the component in Builder and publish again.

## 16. Specialist workspace (Manual)

1. Setup > App Manager > Service Console > Edit > Utility Items > Add Utility Item > Omni-Channel > Save. The utility bar is not in source.
2. In Lightning App Builder, open the Messaging Session record page, replace the Conversation component with Enhanced Conversation, save, and activate it as the org default. Without it an accepted chat opens with no conversation pane (`escalation-and-chat.md` section 7).
3. App Launcher > Service Console > Omni-Channel utility > set status Available - Messaging. If that status is missing, re-run step 9 and reload the console.

Verify: the step 9 permission set and queue member queries return the admin.

Rollback: remove the utility item and restore the previous record page activation.

## 17. Agent tests and end-to-end chat

Automated tests run in Testing Center. `sf agent test create` writes `force-app/main/default/aiEvaluationDefinitions/Northwind_Service_Agent_Tests.aiEvaluationDefinition-meta.xml` and deploys it.

```bash
sf agent test create --spec specs/Northwind_Service_Agent-testSpec.yaml --api-name Northwind_Service_Agent_Tests --test-runner testing-center -o $ORG
sf agent test run --api-name Northwind_Service_Agent_Tests --wait 20 --result-format human -o $ORG
sf agent test results --job-id <JOB_ID> --result-format json --verbose --output-dir test-results -o $ORG
sf agent test run-eval --spec specs/Northwind_Service_Agent-factChecks-testSpec.yaml --result-format human -o $ORG   # optional, deploys nothing
```

Expected on agent version 6: 18 of 18 topic and action assertions and 17 of 18 outcomes, as in run `4KBXXXXXXXXXXXXXXX` on September 15, 2026. Escalation cases TC10 to TC12 report the platform topic `human`, and the one expected outcome miss is TC11 (`docs/TEST_PLAN.md` section 8).

After any change to the document subagents, also run the mandatory search check in `docs/TEST_PLAN.md` section 6.1: six utterances, each sent in five new preview sessions, with a `NW_Doc_*` call expected in every trace.

End-to-end in a browser (Manual; `docs/TEST_PLAN.md` section 7):

1. The specialist is Available - Messaging (step 16).
2. As a guest on `/support`, ask a warranty question (cited answer), "T200 error codes list", "Summarize the returns policy" and "How much does the Halo Video Doorbell cost?" (the agent says it can't find it), then "I want to talk to a person".
3. The specialist accepts the chat in Omni-Channel and replies. Repeat with the specialist Offline: the chat waits in `NW_Live_Support` and is offered to the specialist as soon as they go Available.
4. Capture the records:

```bash
sf data query -o $ORG -q "SELECT Id, Status, ChannelType, AgentType, OwnerId, CreatedDate FROM MessagingSession ORDER BY CreatedDate DESC LIMIT 5"
sf data query -o $ORG -q "SELECT Id, WorkItemId, UserId, Status, OriginalQueueId, RoutingType, BotId FROM AgentWork ORDER BY CreatedDate DESC LIMIT 5"
```

Rollback: delete the test definition in Testing Center if it is no longer wanted. Test runs don't change configuration.

## Requirements and steps

| ID | Requirement | Steps |
| --- | --- | --- |
| REQ-01 | Retrieval through Data Cloud | 1, 2, 8 |
| REQ-02 | Answers, summaries and specific details from unstructured documents, from a question or keywords | 1, 8, 10, 17 |
| REQ-03 | Document chunking and grounded responses | 1, 2, 8 |
| REQ-04 | Prompt templates for each response type | 8 |
| REQ-05 | Subagent routing | 10, 11 |
| REQ-06 | Handoff to a live specialist | 3 to 6, 9, 10, 16, 17 |
| REQ-07 | Agent on the Experience Cloud customer portal | 7, 12 to 15, 17 |

The requirement register, with what was delivered for each item and how to demonstrate it, is in `docs/evidence/BUILD_EVIDENCE.md`.
