# Northwind Service Agent Setup Guide

The finished build has the four Northwind Home PDFs indexed in Data Cloud, three prompt templates, the published agent with its router and six subagents, handoff to a live specialist through Omni-Channel, and guest chat on the Northwind Support portal. Expect about 2 hours of hands-on work, plus the wait for Data Cloud provisioning and up to 90 minutes while the PDFs are indexed. Steps 4 to 20 name the matching step in [docs/BUILD_RUNBOOK.md](docs/BUILD_RUNBOOK.md), which has the full detail and the rollback for each one. Steps 1 to 3 cover the runbook's org values section and the Data Cloud note in its step 0.

## What you need

### A Salesforce org

- A Developer Edition org that includes Agentforce and Data Cloud. The reference build ran in one, on API 67.0 (this project's `sourceApiVersion` is 66.0). It didn't use a scratch org, and [config/project-scratch-def.json](config/project-scratch-def.json) has no Agentforce or Data Cloud features.
- These features must be available: Agentforce, Data Cloud, Service Cloud with Omni-Channel, Messaging for In-App and Web (Enhanced Chat), and Digital Experiences.
- Permission set licenses for the agent user (`AgentforceServiceAgentUserPsl`, `GenieDataPlatformStarterPsl`) and for the specialist (`ServiceUserPsl`, `EmbeddedServiceMessagingUserPsl`, and `LiveMessageUserPsl` if a seat is free), plus the Einstein Agent User profile.
- A system administrator login. The admin you log in with also plays the live specialist in this build.

Step 3 checks the licenses and the profile before you build anything.

### Tools on your computer

| Tool | Used for | Version in the reference build |
| --- | --- | --- |
| Node.js | Installing the Salesforce CLI with npm | not recorded |
| Salesforce CLI, `@salesforce/cli` | Every step | 2.106.6 |
| Agent plugin, `@salesforce/plugin-agent` | Data library, agent, preview and tests | 2.1.1 |
| Community plugin, `@salesforce/plugin-community` | `sf community` commands in the portal script | 3.3.40 |
| git | Getting the code, restoring placeholders | not recorded |
| python3 | JSON parsing in the scripts and commands, the home page script | not recorded |
| curl | The portal HTTP check | not recorded |
| xmllint | Checking the prompt template XML | not recorded |
| unzip | One agent check in step 14 | not recorded |
| reportlab (Python package) | Rebuilding the PDFs only | not recorded |

Install Node.js 22 from nodejs.org first; npm comes with it. On macOS, git, python3, curl, xmllint and unzip come with the Xcode Command Line Tools (`xcode-select --install`). On Debian or Ubuntu, run `sudo apt install git python3 curl libxml2-utils unzip`. On Windows, work through the whole guide in WSL, because the scripts need bash.

Install the CLI and the plugins at the versions this guide was checked against, then check that `sf plugins` lists `agent` and `community`:

```bash
npm install --global @salesforce/cli@2.106.6
sf plugins install @salesforce/plugin-agent@2.1.1
sf plugins install @salesforce/plugin-community@3.3.40
sf --version
sf plugins
```

If npm stops with an EACCES error, run the first line with `sudo`, or install Node.js with nvm so global packages go under your home folder.

Newer versions may work, but some commands and JSON fields used here have changed between releases. For example, `sf project deploy validate` in CLI 2.106.6 rejects `--test-level NoTestRun`, and the `sf agent adl` JSON output differs between releases. If you skip the community plugin, CLI 2.106.6 installs version 3.3.40 by itself the first time an `sf community` command runs. Check the other tools with `git --version`, `python3 --version`, `curl --version`, `xmllint --version` and `unzip -v`.

The CLI prints "update available" warnings on stderr. They do no harm, but they are why the commands here read `--json` output with `2>/dev/null`.

You only need reportlab to rebuild the PDFs in `docs/pdf` after changing the text in `docs/source`:

```bash
python3 -m pip install reportlab
python3 scripts/build_docs.py
```

On Debian or Ubuntu, install it with `sudo apt install python3-reportlab` instead.

### The code

The project is on GitHub at https://github.com/shekharh500/northwind-service-agent. Clone it:

```bash
git clone https://github.com/shekharh500/northwind-service-agent.git
cd northwind-service-agent
```

Run every command in this guide from this folder, in bash or in zsh. The code blocks have `#` comment lines, and zsh, the default shell on macOS, doesn't treat `#` as a comment at the prompt, so it tries to run those lines as commands. In zsh, run `setopt interactivecomments` in each new terminal before the step 2 block, or type `bash` and work in that shell.

The scripts are bash scripts. The `sed -i ''` commands are written for macOS; on Linux, use `sed -i`.

## How the pieces fit

A guest opens the chat on the portal. The chat channel's inbound flow gives the session to the agent. The agent's document subagents run a prompt template, and the template searches the data library through its retriever. When the customer needs a person, the agent runs the escalation flow, which puts the session in the live support queue for a specialist.

| Part | Where it is in the repo | Guide step |
| --- | --- | --- |
| Four source PDFs and their Markdown text | [docs/pdf](docs/pdf), [docs/source](docs/source) | 5 |
| Data library `Northwind_Home_Docs` (search index and retriever) | Created by [scripts/setup-data-library.sh](scripts/setup-data-library.sh) | 5, 6 |
| Prompt templates `NW_Doc_*` | [force-app/main/default/genAiPromptTemplates](force-app/main/default/genAiPromptTemplates) | 6, 12 |
| Settings: Omni-Channel, Messaging, Digital Experiences | [force-app/main/default/settings](force-app/main/default/settings) | 7 |
| Presence status, routing configuration, queue | [servicePresenceStatuses](force-app/main/default/servicePresenceStatuses), [queueRoutingConfigs](force-app/main/default/queueRoutingConfigs), [queues](force-app/main/default/queues) under `force-app/main/default` | 8 |
| Escalation and inbound flows | [force-app/main/default/flows](force-app/main/default/flows) | 9, 16 |
| Specialist permission set | [force-app/main/default/permissionsets](force-app/main/default/permissionsets) | 10 |
| Trusted URLs and CORS origins | [cspTrustedSites](force-app/main/default/cspTrustedSites), [corsWhitelistOrigins](force-app/main/default/corsWhitelistOrigins) under `force-app/main/default` | 11 |
| Agent user and specialist access | [scripts/setup-agent-user.sh](scripts/setup-agent-user.sh) | 13 |
| Agent `Northwind_Service_Agent` | [force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent](force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent) | 14, 15 |
| Messaging channel `NW_Web_Chat` | [force-app/main/default/messagingChannels](force-app/main/default/messagingChannels) | 17 |
| Portal site and chat deployment `NW_Portal_Chat` | [scripts/create-portal.sh](scripts/create-portal.sh); the deployment is created in Setup | 18, 19 |
| Portal home page and site title | [portal/home/home.html](portal/home/home.html), [scripts/update-portal-home.py](scripts/update-portal-home.py), [portal/site](portal/site) | 19 |
| Specialist workspace | Setup only | 20 |
| Agent tests | [specs](specs), [force-app/main/default/aiEvaluationDefinitions](force-app/main/default/aiEvaluationDefinitions), [test-results](test-results) | Check the whole build |

## Step 1. Connect the CLI to your org

Log in and give the org the alias `northwind-dev`, which the manual-steps pages use. Use your org's login URL, `https://<my-domain>.my.salesforce.com`:

```bash
sf org login web --alias northwind-dev --instance-url https://<my-domain>.my.salesforce.com
```

If you don't know the My Domain URL yet, leave out `--instance-url`. The project's `sfdcLoginUrl` is `https://login.salesforce.com`.

Read the org ID and My Domain name, the host of the org URL without `.my.salesforce.com` (for example `acme-dev-ed.develop`). The second command prints both in the form the next step needs:

```bash
sf org display -o northwind-dev
sf org display -o northwind-dev --json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print("EXPECTED_ORG_ID=" + r["id"]); print("MY_DOMAIN=" + r["instanceUrl"].split("//")[1].replace(".my.salesforce.com", ""))'
```

## Step 2. Fill in the org values and load them

The scripts and the runbook commands read the org alias and org-specific values from `config/org-values.local.env`, which you create from [config/org-values.example.env](config/org-values.example.env). Git ignores `config/*.local.env` ([.gitignore](.gitignore)), so your values stay out of the repository.

```bash
cp config/org-values.example.env config/org-values.local.env
```

Open `config/org-values.local.env` and set:

1. `ORG_ALIAS`: leave it as `northwind-dev` unless you used another alias in step 1. `TARGET_ORG` copies it.
2. `EXPECTED_ORG_ID`: the org ID from step 1. The scripts stop while it still reads `__ORG_ID__`, and they refuse to run if the alias points to a different org.
3. `MY_DOMAIN`: the My Domain name from step 1. `SITE_DOMAIN` is built from it.
4. Leave `RETRIEVER_API_NAME` and `AGENT_USER_USERNAME` empty. Steps 6 and 13 fill them in.

Load the file and set the shell variable the runbook commands use:

```bash
set -a; . config/org-values.local.env; set +a
ORG=$ORG_ALIAS
export TMPDIR="${TMPDIR:-/tmp}"
echo "$ORG $TARGET_ORG $EXPECTED_ORG_ID $MY_DOMAIN $SITE_DOMAIN"
```

The last line should show your alias, org ID, My Domain name and `https://<my-domain>.my.site.com`. The `TMPDIR` line only matters on Linux, where it can be empty. Run this block again in every new terminal (after `setopt interactivecomments` in zsh) and after you add a value to the file. Later steps add the shell variables `LIB_ID` (step 5), `AGENT_FILE` (step 14), `SID` (step 15) and `CHAN_ID` (step 18).

Before any deploy, `grep -rnE "__[A-Z][A-Z_]*__" force-app` lists the placeholders that still need a value. Right now that is the three prompt templates, the four Trusted URL and CORS files and the `.agent` file; steps 6, 11 and 14 replace them. Those replacements write your org's values into tracked files, so don't commit them to a public repository. When you are done with the org, `git restore` on the changed files puts the placeholders back (and discards any other edits in those files).

## Step 3. Turn on Agentforce and Data Cloud

Items 1 to 3 are Setup changes with no command. Start them early, because Data Cloud provisioning takes a while.

1. Setup > Quick Find "Agents" > Agentforce Agents. Turn Agentforce on.
2. From the Setup gear menu, choose Data Cloud Setup (Data 360 Setup in newer releases) and click Get Started. Provisioning runs in the background. Carry on with items 3 and 4 and check back now and then. It has finished when `sf agent adl list -o $ORG --json 2>/dev/null` prints `"status": 0`. Nothing from step 5 on works before that, and enabling Digital Experiences in step 7 can fail while provisioning is still running.
3. If the Agentforce Agents page says Einstein generative AI must be on first, turn it on in Setup > Quick Find "Einstein Setup", then go back to item 1.
4. Give yourself the Prompt Template Manager permission set, which deploying the prompt templates requires:

   ```bash
   sf org assign permset --name EinsteinGPTPromptTemplateManager -o $ORG
   ```

   In the reference org the admin also had `GenieAdmin`, `CopilotSalesforceAdmin` and `AgentforceServiceAgentBuilder` ([prompt-templates.md](docs/manual-steps/prompt-templates.md) section 2). Compare with that list if a later step fails on a permission.

Check that the licenses and the agent profile exist:

```bash
sf data query -o $ORG \
  -q "SELECT DeveloperName, TotalLicenses, UsedLicenses FROM PermissionSetLicense WHERE DeveloperName IN ('AgentforceServiceAgentUserPsl','GenieDataPlatformStarterPsl','ServiceUserPsl','EmbeddedServiceMessagingUserPsl','LiveMessageUserPsl')"
sf data query -o $ORG \
  -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User' AND UserLicense.Name = 'Einstein Agent'"
```

The first query must list each license with `UsedLicenses` lower than `TotalLicenses`. `LiveMessageUserPsl` is optional, and a specialist license that is already assigned to you doesn't need a free seat.

- If `AgentforceServiceAgentUserPsl` or `GenieDataPlatformStarterPsl` is missing, finish items 1 and 2 and query again. If it is still missing, this org can't host the agent user.
- If `ServiceUserPsl` or `EmbeddedServiceMessagingUserPsl` is missing or has no seat for you, this org can't hand chats to a specialist, so use another org.
- The profile query must return one row. If it returns none, Agentforce is not on yet.

## Step 4. Run the preflight checks (runbook step 0)

These commands only read from the org.

```bash
# Expect your org ID and your My Domain URL on my.salesforce.com
sf org display -o $ORG --json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r["id"], r["instanceUrl"])'

# Must return status 0, which means the data library API is available
sf agent adl list -o $ORG --json 2>/dev/null

# Expect default
sf data query -o $ORG -q "SELECT Id, Name, Status FROM DataSpace"

# One row once the site exists
sf data query -o $ORG \
  -q "SELECT Id, Name, Status, UrlPathPrefix FROM Network WHERE Name = 'Northwind Support'"

# Checks the org ID, the data library API and the 4 PDFs in docs/pdf
scripts/setup-data-library.sh preflight
```

In a new org the `Network` query errors until step 7 enables Digital Experiences, then returns no rows until step 18 creates the site. If `sf agent adl list` errors, Data Cloud provisioning hasn't finished; wait and run it again before you go on.

## Step 5. Create the data library and load the PDFs (runbook step 1)

This creates the Agentforce Data Library `Northwind_Home_Docs` with the uploaded-files source and the enhanced index, and uploads the four PDFs from [docs/pdf](docs/pdf). Creating the library sets up the Data Cloud pipeline: data lake object, data model object, a hybrid search index that splits each PDF into chunks of up to 512 tokens, and a retriever. [scripts/setup-data-library.sh](scripts/setup-data-library.sh) skips `create` if the library exists and uploads only files that are missing by name.

Preview, then run. Runbook step 1 Option B has the same work as raw `sf agent adl` commands.

```bash
# Preview
DRY_RUN=1 scripts/setup-data-library.sh all

# WAIT_MINUTES defaults to 45
scripts/setup-data-library.sh create upload wait
```

`upload` waits up to 45 minutes for indexing, and `wait` then polls every 30 seconds for up to another 45. The run is done when it prints a line with `retrieverId 1Cx...`. If it stops with `retriever not ready after 45 minutes`, indexing is still running in the org; run `scripts/setup-data-library.sh wait` again.

Then set `LIB_ID`, which the checks below and step 6 use. Set it again in any new terminal.

```bash
LIB_ID=$(sf agent adl list -o $ORG --json 2>/dev/null | python3 -c 'import json,sys; print(next(l["libraryId"] for l in json.load(sys.stdin)["result"]["libraries"] if l["developerName"]=="Northwind_Home_Docs"))')

# Starts with 1JD
echo "$LIB_ID"
```

Check the result:

```bash
# READY, and DATA_LAKE_OBJECT, DATA_MODEL_OBJECT, SEARCH_INDEX, RETRIEVER and INDEXING all SUCCESS
sf agent adl status -o $ORG -i "$LIB_ID" --include-artifacts

# 4 files
sf agent adl file list -o $ORG -i "$LIB_ID" --status indexed

# Status READY, Retriever ID present
sf agent adl get -o $ORG -i "$LIB_ID"
```

![Data library ready](docs/demo/16-data-library.png)

Setup > Quick Find "Agentforce Data Library": Northwind Home Docs with data source Files and status Ready.

![Data library pipeline](docs/demo/17-data-library-pipeline.png)

The library detail page with a green check on each Data Cloud stage.

![Four indexed PDFs](docs/demo/18-data-library-files.png)

The Files section lists the four PDFs as Indexed. The warning icon on the warranty policy is left over from a failed file delete in the reference org ([demo.md](demo.md) step 15).

![Search index](docs/demo/19-search-index.png)

The index record, opened from the Search Index link on the library page: search type Hybrid over the library's data model object, last run status Ready.

![Chunking and embedding model](docs/demo/20-chunking-vectors.png)

The Configuration tab: section-aware chunking for PDFs, 512 tokens with no overlap, and the E5 Large V2 embedding model.

If you change a PDF after this step, don't upload it again. Runbook step 1, "Replacing documents in an existing library", has the delete-and-add procedure that keeps the same retriever.

## Step 6. Put the retriever name into the prompt templates (runbook step 2)

The three templates in [force-app/main/default/genAiPromptTemplates](force-app/main/default/genAiPromptTemplates) hold the placeholder `__RETRIEVER_API_NAME__`, three times per file. It has to become the retriever's API name, which has the shape `File_Northwind_Home_Docs_1Cx_<hash>`, not its record ID or its display name. In the reference org the CLI didn't return that name, so expect to read it in Prompt Builder or Einstein Studio.

First print the retriever the CLI reports, so you can tell which one to pick:

```bash
sf agent adl get -o $ORG -i "$LIB_ID" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("retriever"))'
```

Expect an ID that starts with 1Cx and a label such as `File_Northwind_Home_Docs`. The API name is that label followed by `_1Cx_` and a hash, with no spaces. Prompt Builder can show the same retriever under another display name, such as Northwind Docs Retriever in the step 12 screenshot.

1. Setup > Quick Find "Prompt Builder". Open any Flex template. If the org has none, click New Prompt Template, choose Flex, give it a throwaway name such as `Retriever Lookup`, add a free-text source and click Next ([prompt-templates.md](docs/manual-steps/prompt-templates.md) section 7, step 4). Don't use one of the `NW_Doc_*` names, because step 12 deploys those.
2. Insert Resource > Retrievers (Einstein Search in some releases) > the Northwind library retriever, labeled `File_Northwind_Home_Docs`.
3. The retriever settings that open include a read-only field with a value like `EinsteinSearch:File_Northwind_Home_Docs_1Cx_<hash>`. The API name is the part after `EinsteinSearch:`. This is where the reference build read it. If the prompt shows the merge field as text, the same name is inside `{!$EinsteinSearch:<API_NAME>.results}`. In a saved template the retriever can also appear as a pill, such as `Retrievers:Northwind Docs Retriever`, which doesn't show the name. Einstein Studio > Retrievers also lists the library's retriever ([TEST_PLAN.md](docs/TEST_PLAN.md) section 5.3).
4. Cancel without saving. If Prompt Builder saved the throwaway template, delete it.

In `config/org-values.local.env`, set `RETRIEVER_API_NAME=<API name>`. Then reload the file and apply the name. `apply` edits the three templates, checks that no placeholder is left, that each file has 3 hits and that the XML is valid. It doesn't connect to the org.

```bash
set -a; . config/org-values.local.env; set +a
scripts/setup-data-library.sh apply
```

If reloading the file prints `command not found`, the value has spaces because you copied a display name, and `apply` then stops with `no retriever API name`. If you put a display name in quotes, `apply` stops with `unexpected retriever API name`. `apply` only checks the characters, so a name without the `_1Cx_` part passes here and fails at the step 12 deploy.

If your CLI release does return the name, run `scripts/setup-data-library.sh resolve apply` while `RETRIEVER_API_NAME` is empty. It looks the name up, prints it and applies it. Copy the printed name into `RETRIEVER_API_NAME` in `config/org-values.local.env` and reload the file before the checks below, which read that variable. The lookup commands are in [prompt-templates.md](docs/manual-steps/prompt-templates.md) section 3.

Check the result:

```bash
# 0 for each file
grep -c "__RETRIEVER_API_NAME__" force-app/main/default/genAiPromptTemplates/*.xml

# 3 for each file
grep -c "$RETRIEVER_API_NAME" force-app/main/default/genAiPromptTemplates/*.xml

# OK for each file
for f in force-app/main/default/genAiPromptTemplates/*.xml; do
  xmllint --noout "$f" && echo "OK $f"
done
```

The three template files now hold your org's retriever name. Don't commit them to a public repository. When you are done with the org, `git restore force-app/main/default/genAiPromptTemplates` puts the placeholder back.

## Step 7. Deploy the Omni-Channel, Messaging and Digital Experiences settings (runbook step 3)

The files in [force-app/main/default/settings](force-app/main/default/settings) turn on Omni-Channel (skills routing and status-based capacity stay off), Messaging (the channel needs it in step 17) and Digital Experiences. Digital Experiences can't be turned off again. `ExperienceBundle.settings` is optional and only helps with Aura sites.

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/settings/OmniChannel.settings-meta.xml \
  --source-dir force-app/main/default/settings/LiveMessage.settings-meta.xml \
  --source-dir force-app/main/default/settings/Communities.settings-meta.xml

# Optional, after the deploy above
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/settings/ExperienceBundle.settings-meta.xml
```

Check the result:

```bash
rm -rf "$TMPDIR/nw-settings-check"
sf project retrieve start -o $ORG \
  --metadata Settings:OmniChannel --metadata Settings:LiveMessage \
  --target-metadata-dir "$TMPDIR/nw-settings-check" --unzip --wait 20 >/dev/null

# Both true
grep -rh "enableOmniChannel\|enableLiveMessage" "$TMPDIR/nw-settings-check"

# Must not error
sf data query -o $ORG -q "SELECT Id FROM Network LIMIT 1"
```

If the deploy rejects a setting, use Setup ([escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 5.1, [experience-portal.md](docs/manual-steps/experience-portal.md) section 4.2):

1. Messaging: Setup > Quick Find "Messaging Settings" > Messaging Settings. Turn on the Messaging toggle at the top.
2. Digital Experiences: Setup > Quick Find "Digital Experiences" > Settings. Select Enable Digital Experiences, save and confirm. The domain shown, `<my-domain>.my.site.com`, can't be edited.

## Step 8. Deploy the presence status, routing configuration and queue (runbook step 4)

This deploys the presence status Available - Messaging (`NW_Available_Messaging`), the routing configuration `NW_Messaging_Routing` (Most Available, 60-second push timeout) and the queue Northwind Live Support (`NW_Live_Support`), which takes Messaging Session work. Deploy, then check the result:

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/servicePresenceStatuses \
  --source-dir force-app/main/default/queueRoutingConfigs \
  --source-dir force-app/main/default/queues

sf data query -o $ORG \
  -q "SELECT Id, DeveloperName FROM ServicePresenceStatus WHERE DeveloperName='NW_Available_Messaging'"
sf data query -o $ORG \
  -q "SELECT Id, DeveloperName FROM QueueRoutingConfig WHERE DeveloperName='NW_Messaging_Routing'"

# QueueRoutingConfigId is not empty
sf data query -o $ORG \
  -q "SELECT Id, DeveloperName, QueueRoutingConfigId FROM Group WHERE Type='Queue' AND DeveloperName='NW_Live_Support'"

# MessagingSession
sf data query -o $ORG \
  -q "SELECT SobjectType FROM QueueSobject WHERE Queue.DeveloperName='NW_Live_Support'"
```

Queue members aren't part of the queue metadata. If you ever redeploy the queue, run step 13 again to restore the specialist's membership.

## Step 9. Deploy the escalation flow (runbook step 5)

`NW_Escalate_To_Live_Agent` finds the `NW_Live_Support` queue and routes the messaging session to it, where the chat waits for the next available specialist. The agent's connection blocks name this flow, so it must be active before you publish the agent in step 14. Don't deploy the other flow, `NW_Route_Messaging_To_Agent`, yet; that is step 16.

Deploy, then check the result:

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/flows/NW_Escalate_To_Live_Agent.flow-meta.xml

# ActiveVersionId is not empty, ProcessType is RoutingFlow
sf data query -o $ORG \
  -q "SELECT ApiName, ActiveVersionId, ProcessType FROM FlowDefinitionView WHERE ApiName='NW_Escalate_To_Live_Agent'"
```

![Escalation flow](docs/demo/28-escalation-flow.png)

The flow in Flow Builder: Get Live Support Queue, then Route To Live Support Queue, marked Active. The reference org shows V3 because the flow was changed twice there; the version number in your org doesn't matter as long as one version is active.

## Step 10. Deploy the specialist permission set (runbook step 6)

`NW_Live_Support_Agent` gives the specialist the Available - Messaging status and the Enhanced Chat user permissions. Step 13 assigns it. Deploy, then check the result:

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/permissionsets/NW_Live_Support_Agent.permissionset-meta.xml
sf data query -o $ORG \
  -q "SELECT Id, Name, Label FROM PermissionSet WHERE Name='NW_Live_Support_Agent'"
```

Steps 7 to 10 can also go in one `sf project deploy start` with all of their `--source-dir` flags.

## Step 11. Set your domain in the Trusted URLs and CORS entries, then deploy them (runbook step 7)

The chat component on the portal talks to your site domain and to the Enhanced Chat runtime host (SCRT). The four files in [force-app/main/default/cspTrustedSites](force-app/main/default/cspTrustedSites) and [force-app/main/default/corsWhitelistOrigins](force-app/main/default/corsWhitelistOrigins) hold the placeholder `__MY_DOMAIN__` (in `NW_Messaging_SCRT` only in the description). Replace it with your My Domain name:

```bash
# Your My Domain name, not empty and not the placeholder
echo "$MY_DOMAIN"
```

Don't run the `sed` below while that prints an empty line; load the env file first (step 2).

```bash
sed -i '' "s/__MY_DOMAIN__/${MY_DOMAIN}/g" \
  force-app/main/default/cspTrustedSites/*.cspTrustedSite-meta.xml \
  force-app/main/default/corsWhitelistOrigins/*.corsWhitelistOrigin-meta.xml

# No output
grep -rn "__MY_DOMAIN__" \
  force-app/main/default/cspTrustedSites force-app/main/default/corsWhitelistOrigins

grep -rh "endpointUrl\|urlPattern" \
  force-app/main/default/cspTrustedSites force-app/main/default/corsWhitelistOrigins
```

The last command should show `https://*.salesforce-scrt.com`, `https://<my-domain>.my.site.com` and `https://<my-domain>.my.salesforce-scrt.com`. Then deploy and check the result:

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/cspTrustedSites \
  --source-dir force-app/main/default/corsWhitelistOrigins

# 2 rows
sf data query -o $ORG \
  -q "SELECT DeveloperName, EndpointUrl, Context, IsActive FROM CspTrustedSite WHERE DeveloperName LIKE 'NW_%'"

# 2 rows
sf data query -o $ORG -q "SELECT DeveloperName, UrlPattern FROM CorsWhitelistEntry"
```

These four files now hold your domain. Don't commit them to a public repository. When you are done with the org, `git restore force-app/main/default/cspTrustedSites force-app/main/default/corsWhitelistOrigins` puts the placeholder back.

## Step 12. Deploy the prompt templates and check them (runbook step 8)

This deploys the three Flex templates: Northwind - Answer Question (`NW_Doc_Answer_Question`), Northwind - Summarize Topic (`NW_Doc_Summarize`) and Northwind - Extract Details (`NW_Doc_Extract_Details`). Each one grounds its answer on the retriever and returns a fixed "couldn't find" sentence when nothing relevant comes back. The deploy fails with "cannot describe data provider" if step 6 isn't done or the retriever isn't ready.

```bash
sf project deploy validate -o $ORG --wait 15 --test-level RunLocalTests \
  --source-dir force-app/main/default/genAiPromptTemplates
sf project deploy start -o $ORG --wait 15 \
  --source-dir force-app/main/default/genAiPromptTemplates
```

Check the result:

```bash
# 3 names
sf org list metadata --metadata-type GenAiPromptTemplate -o $ORG --json 2>/dev/null \
  | grep -E '"fullName": "NW_Doc_'

rm -rf "$TMPDIR/nw-gapt-check"
sf project retrieve start -o $ORG --target-metadata-dir "$TMPDIR/nw-gapt-check" --unzip \
  -m "GenAiPromptTemplate:NW_Doc_Answer_Question" \
  -m "GenAiPromptTemplate:NW_Doc_Summarize" \
  -m "GenAiPromptTemplate:NW_Doc_Extract_Details"

# The 3 pinned values ending in _1 from prompt-templates.md section 1
grep -rh "activeVersionIdentifier" "$TMPDIR/nw-gapt-check"
```

If the identifiers differ from the three in prompt-templates.md section 1, for example because a template was rebuilt in Prompt Builder, retrieve the three templates into `force-app` so later deploys don't conflict ([prompt-templates.md](docs/manual-steps/prompt-templates.md) section 5).

Then, in Setup (required):

1. Setup > Prompt Builder, search for `Northwind`. All three templates must be active on version 1. Activate any that are not.
2. Open each template, click Preview and enter the Query value (Topic for Northwind - Summarize Topic). The Resolved Prompt panel shows the prompt with the retrieved chunks, and the Generated Response panel shows the answer. Don't save.

| Template | Input | The response should contain |
| --- | --- | --- |
| Northwind - Answer Question | `How long is the warranty if I register my thermostat within 30 days?` | 36 months (standard 24), cited to the Limited Warranty Policy |
| Northwind - Answer Question | `What is the price of the Halo Video Doorbell?` | Exactly `I couldn't find that in the Northwind Home documentation.` |
| Northwind - Extract Details | `Aura T200 error codes` | Bullets for E1 to E6 |

More inputs are in [prompt-templates.md](docs/manual-steps/prompt-templates.md) section 6. If Prompt Builder shows the model as unavailable, pick another model, Save As New Version, activate it and retrieve the template (section 5 of the same page).

![Prompt templates](docs/demo/21-prompt-templates.png)

The three Northwind Flex templates in Prompt Builder, all Active.

![Answer Question template](docs/demo/22-prompt-template-retriever.png)

Northwind - Answer Question on Version 1 (Active), with the `Input:Query` input and the retriever resource in the prompt, shown as the pill Retrievers:Northwind Docs Retriever.

## Step 13. Create the agent user and set up the specialist (runbook step 9)

[scripts/setup-agent-user.sh](scripts/setup-agent-user.sh) checks before each change, so it is safe to run again. It:

1. Creates the Einstein Agent user the agent runs as, with the licenses `AgentforceServiceAgentUserPsl` and `GenieDataPlatformStarterPsl` and the permission sets `AgentforceServiceAgentUser` and `GenieUserEnhancedSecurity` (Data Cloud User).
2. Gives you, the admin and specialist, `ServiceUserPsl`, `EmbeddedServiceMessagingUserPsl`, `LiveMessageUserPsl` if a seat is free, and `NW_Live_Support_Agent`.
3. Adds you to the queue `NW_Live_Support`.

It needs steps 8 and 10 done first. The last line it prints is the agent username.

```bash
# Preview, no writes
DRY_RUN=1 scripts/setup-agent-user.sh $ORG

AGENT_USER_USERNAME=$(scripts/setup-agent-user.sh $ORG | tail -1)
echo "$AGENT_USER_USERNAME"
```

If `echo` prints an empty line, the script stopped before it finished. Read the ERROR line above it, fix the cause and run it again.

The default username is `nwagent.` followed by your username. To choose another, for example because that username is taken in another org, set `AGENT_USERNAME` before the command. Read any warnings the script prints at the end; they name licenses or permission sets it couldn't assign. Then, in `config/org-values.local.env`, set `AGENT_USER_USERNAME=` to the printed username, then reload the file (step 2 block).

Check the result:

```bash
sf data query -o $ORG \
  -q "SELECT Username, IsActive, Profile.Name FROM User WHERE Username='$AGENT_USER_USERNAME'"

# AgentforceServiceAgentUser and GenieUserEnhancedSecurity
sf data query -o $ORG \
  -q "SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username='$AGENT_USER_USERNAME' AND PermissionSet.IsOwnedByProfile = false"

# Your admin username
sf data query -o $ORG \
  -q "SELECT Assignee.Username FROM PermissionSetAssignment WHERE PermissionSet.Name='NW_Live_Support_Agent'"

# Your admin user ID
sf data query -o $ORG \
  -q "SELECT UserOrGroupId FROM GroupMember WHERE Group.DeveloperName='NW_Live_Support'"
```

Then check data space access, which has no API. Open Setup > Quick Find "Permission Sets" > Data Cloud User. If the page has a Data Space Access section, open it, add the `default` data space and save ([experience-portal.md](docs/manual-steps/experience-portal.md) section 8). If the section isn't there, skip this.

In the reference org the agent user answers with only its two permission sets. If live answers later come back as "couldn't find" while Prompt Builder previews work, check the data space access first. Then assign `EinsteinGPTPromptTemplateUser` (Prompt Template User) to the agent user in Setup > Users > Permission Set Assignments and test again ([prompt-templates.md](docs/manual-steps/prompt-templates.md) section 6).

## Step 14. Publish and activate the agent (runbook step 10)

The agent is defined in Agent Script in [Northwind_Service_Agent.agent](force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent). Its `default_agent_user` holds the placeholder `__AGENT_USER_USERNAME__`. Replace it with the username from step 13, then validate, publish and activate. Publishing needs the active escalation flow (step 9), the active templates (step 12) and the agent user (step 13).

```bash
AGENT_FILE=force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent
if [ -n "$AGENT_USER_USERNAME" ]; then
  sed -i '' "s/__AGENT_USER_USERNAME__/${AGENT_USER_USERNAME}/" "$AGENT_FILE"
else
  echo "AGENT_USER_USERNAME is empty: set it in the env file and reload it (step 2)"
fi

# Shows your agent username, not the placeholder
grep -n "default_agent_user" "$AGENT_FILE"
```

If the `grep` shows `default_agent_user: ""`, the value was empty when the placeholder was replaced. Run `git restore "$AGENT_FILE"`, set the value and run the block again.

Then validate, publish and activate:

```bash
# success is true
sf agent validate authoring-bundle --api-name Northwind_Service_Agent \
  -o $ORG --json 2>/dev/null

# Returns botId and botVersionId
sf agent publish authoring-bundle --api-name Northwind_Service_Agent \
  -o $ORG --skip-retrieve --json 2>/dev/null

# With --json and no --version, this activates the latest version
sf agent activate --api-name Northwind_Service_Agent -o $ORG --json 2>/dev/null
```

`--skip-retrieve` stops publish from writing Bot, GenAiPlugin, GenAiFunction and Agent folders into `force-app`. Validation doesn't check that the templates, flow or agent user exist; publish does.

Check the result:

```bash
sf data query -o $ORG \
  -q "SELECT Id, DeveloperName FROM BotDefinition WHERE DeveloperName='Northwind_Service_Agent'"

# The latest version is Active
sf data query -o $ORG \
  -q "SELECT Id, VersionNumber, Status FROM BotVersion WHERE BotDefinition.DeveloperName='Northwind_Service_Agent' ORDER BY VersionNumber"
```

Then confirm the escalation route on the published agent. This command prints the planner bundle names for the agent:

```bash
sf org list metadata --metadata-type GenAiPlannerBundle -o $ORG --json 2>/dev/null \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"] or []; r=r if isinstance(r,list) else [r]; print("\n".join(x["fullName"] for x in r if "northwind" in x["fullName"].lower()))'
```

Replace `<FULL_NAME_FROM_LIST>` below with the printed name. If it prints several names, pass each with its own `--metadata` flag.

```bash
mkdir -p "$TMPDIR/nw-agent-verify"
sf project retrieve start -o $ORG \
  --metadata "GenAiPlannerBundle:<FULL_NAME_FROM_LIST>" \
  --target-metadata-dir "$TMPDIR/nw-agent-verify"
unzip -o "$TMPDIR/nw-agent-verify/unpackaged.zip" -d "$TMPDIR/nw-agent-verify" >/dev/null
grep -rn "surfaceType\|outboundRouteName\|outboundRouteType\|escalationMessage" \
  "$TMPDIR/nw-agent-verify"
```

Expect two surfaces, Messaging and CustomerWebClient, each with `outboundRouteType` OmniChannelFlow and `outboundRouteName` for `NW_Escalate_To_Live_Agent` ([agent.md](docs/manual-steps/agent.md) section 7).

![Agents list](docs/demo/23-agents-list.png)

App Launcher > Agentforce Studio > Agents lists Northwind Service Agent.

![Agent in Agentforce Builder](docs/demo/24-agent-builder.png)

The agent in Agentforce Builder: the Agent Router, six subagents, and the Enhanced Chat v2 and Messaging connections. The reference org shows version 6; the file you published is the same script, and your org starts at version 1.

![Escalation flow and message](docs/demo/27-escalation-flow-setting.png)

Connections > Messaging > Settings: escalation flow NW Escalate To Live Agent and the escalation message with the disconnect-power line.

The `.agent` file now holds your agent username. Don't commit it to a public repository. When you are done with the org, `git restore` on the file puts the placeholder back. The design behind the router, the mandatory search and the escalation triggers is in [agent.md](docs/manual-steps/agent.md) section 1.

## Step 15. Run a preview smoke test (runbook step 11)

Do this before any channel work. It runs the published agent with the real templates and retriever, and reads the trace for each turn.

```bash
SID=$(sf agent preview start --api-name Northwind_Service_Agent -o $ORG --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["sessionId"])')

sf agent preview send --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG \
  -u "If I register my Aura thermostat within 30 days, how long is my warranty?"
sf agent preview send --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG \
  -u "Summarize the returns and refunds policy"
sf agent preview send --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG \
  -u "List every Aura T200 error code and what it means"
sf agent preview end --api-name Northwind_Service_Agent --session-id "$SID" -o $ORG

# document_qa, document_summary, detail_finder
sf agent trace read -s "$SID" -f detail -d routing

# One or more NW_Doc template calls per turn, with the rewritten query as input
sf agent trace read -s "$SID" -f detail -d actions
```

Expected answers: 36 months (standard 24) with the warranty policy cited, a sectioned returns summary, and error codes E1 to E6. Each of the three turns must show a `NW_Doc_*` call in the actions trace. If one doesn't, see [agent.md](docs/manual-steps/agent.md) section 10. Don't test escalation here. A preview session has no messaging session, so an escalation returns an Escalate message with no text and no trace, and any later send in that session fails. The real handoff is tested on the portal.

## Step 16. Deploy the inbound routing flow (runbook step 12)

`NW_Route_Messaging_To_Agent` gives each new chat to the agent, with the queue as the fallback. It refers to the agent by name, and a reference to an agent that doesn't exist still deploys, but then every chat goes to the queue. That is why it comes after step 14.

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/flows/NW_Route_Messaging_To_Agent.flow-meta.xml

# ActiveVersionId is not empty
sf data query -o $ORG \
  -q "SELECT ApiName, ActiveVersionId FROM FlowDefinitionView WHERE ApiName='NW_Route_Messaging_To_Agent'"
```

Then check the agent reference in Setup (required):

1. Setup > Process Automation > Flows > NW Route Messaging To Agent > open the active version.
2. Open the Route To Northwind Service Agent element. The agent field must show Northwind Service Agent.
3. If it is blank, select Northwind Service Agent, Save As New Version and Activate.

## Step 17. Deploy and activate the messaging channel (runbook step 13)

`NW_Web_Chat` (Northwind Web Chat) is the Enhanced Chat channel, in unauthenticated mode so guests can chat. It needs Messaging on (step 7), the queue (step 8) and the active inbound flow (step 16).

```bash
sf project deploy start -o $ORG --wait 30 \
  --source-dir force-app/main/default/messagingChannels/NW_Web_Chat.messagingChannel-meta.xml

# SessionHandlerId starts with 300, FallbackQueueId with 00G, IsActive is false until activated
sf data query -o $ORG \
  -q "SELECT DeveloperName, MessageType, RoutingType, SessionHandlerId, FallbackQueueId, IsActive FROM MessagingChannel WHERE DeveloperName='NW_Web_Chat'"
```

Activate it in Setup. This is the recommended route, because it includes accepting the Enhanced Chat terms:

1. Setup > Quick Find "Messaging Settings" > Northwind Web Chat.
2. In Omni-Channel Routing, check: Routing Type Omni-Channel Flow, Flow Definition NW Route Messaging To Agent, Fallback Queue Northwind Live Support. Set any missing value with the pencil icon.
3. Click Activate, accept the terms and conditions, and save.

The runbook's CLI alternative is a direct data update: `sf data update record -o $ORG --sobject MessagingChannel --where "DeveloperName='NW_Web_Chat'" --values "IsActive=true"`. Either way, run the MessagingChannel query again; `IsActive` should be true.

![Messaging channel](docs/demo/31-messaging-channel.png)

Messaging Settings with the Messaging toggle on and Northwind Web Chat listed as an active Enhanced channel.

## Step 18. Create the portal site and the chat deployment (runbook steps 15 and 14)

The embedded service deployment needs the site to exist, so this step creates and activates the site first (the first command group of runbook step 15), then creates `NW_Portal_Chat` (runbook step 14). This is the order in [experience-portal.md](docs/manual-steps/experience-portal.md) section 3.

### Create and activate the site

[scripts/create-portal.sh](scripts/create-portal.sh) creates Northwind Support from the Build Your Own (LWR) template at `/support`, with public access enabled, and skips `create` if the site exists. It reads `ORG_ALIAS`, `EXPECTED_ORG_ID` and `SITE_DOMAIN` from the environment, and nothing it retrieves is written under `force-app`.

```bash
# Your alias and your site URL on my.site.com
echo "$ORG_ALIAS $SITE_DOMAIN"

# Read-only
scripts/create-portal.sh status

# Prints the commands that would change the org
DRY_RUN=1 scripts/create-portal.sh all

scripts/create-portal.sh preflight create retrieve activate

# Status Live
sf data query -o $ORG \
  -q "SELECT Id, Name, Status FROM Network WHERE Name='Northwind Support'"
```

`activate` sets the site status to Live, which also sends the site welcome email to its members; on a new site the only member profile is the admin's.

If the script route is rejected, use the click path in [experience-portal.md](docs/manual-steps/experience-portal.md) section 5.2:

1. Setup > Digital Experiences > All Sites > New > Build Your Own (LWR). Name `Northwind Support`, URL `support`.
2. Setup > Quick Find "All Sites" > Builder next to Northwind Support > Settings > General. Select Public can access the site.
3. Setup > Quick Find "All Sites" > Workspaces next to Northwind Support > Administration > Settings. Click Activate.

### Create the chat deployment NW_Portal_Chat

Web deployments can't be deployed as metadata. Print the domain you'll enter in item 4:

```bash
echo "$MY_DOMAIN.my.site.com"
```

Create the deployment in Setup (recommended):

1. Setup > Quick Find "Embedded Service" > Embedded Service Deployments > New Deployment.
2. Select Messaging for In-App and Web (may be labeled Enhanced Chat) > Next.
3. Select Web > Next.
4. Embedded Service Deployment Name `NW Portal Chat`, API Name `NW_Portal_Chat`, Domain: the value printed above, Messaging Channel Northwind Web Chat. If asked to choose between an Experience Cloud site and another website, choose the Experience Cloud site Northwind Support.
5. Save. On the deployment settings page, click Publish. Publishing can take up to 10 minutes to take effect.

Or use the Connect API. Run it once only; it is not idempotent.

```bash
CHAN_ID=$(sf data query -o $ORG --json -q "SELECT Id FROM MessagingChannel WHERE DeveloperName='NW_Web_Chat'" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['Id'])")

sf api request rest "/services/data/v67.0/connect/embeddedmessaging/deployment/setup" \
  -X POST -o $ORG \
  --body "{\"name\":\"NW_Portal_Chat\",\"masterLabel\":\"NW Portal Chat\",\"deploymentType\":\"Web\",\"clientVersion\":\"WebV2\",\"hostDomain\":\"${MY_DOMAIN}.my.site.com\",\"messagingChannelId\":\"${CHAN_ID}\"}"
```

Then open NW Portal Chat in Setup > Embedded Service Deployments and click Publish. Step 19 needs a published deployment, and publishing can take up to 10 minutes ([escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 6, [experience-portal.md](docs/manual-steps/experience-portal.md) section 6.1). To publish again after a later change, use the `publish` request in [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 6.

Check the result:

```bash
# One row with DeploymentType Web and ClientVersion WebV2
sf data query -o $ORG --use-tooling-api \
  -q "SELECT Id, DeveloperName, DeploymentType, IsEnabled, ClientVersion FROM EmbeddedServiceConfig WHERE DeveloperName='NW_Portal_Chat'"

# Auto-generated ESW sites, at least one with a UrlPathPrefix that does not end in vforcesite
sf data query -o $ORG \
  -q "SELECT Name, UrlPathPrefix, SiteType, Status FROM Site WHERE Name LIKE 'ESW_NW_Portal_Chat%'"

# Read-only. Shows ESD NW_Portal_Chat with a siteEndpoint on your site domain
scripts/create-portal.sh status
```

Creating the deployment generates one or more `ESW_NW_Portal_Chat_<timestamp>` sites. Leave them alone. Guest chat comes from the channel's unauthenticated mode, so you don't need to change the deployment's guest-user flag.

![Embedded service deployment](docs/demo/29-embedded-service.png)

NW Portal Chat listed under Embedded Service Deployments, type Web, client version WebV2.

## Step 19. Add the chat to the portal and publish (runbook step 15)

`messaging` adds the Embedded Messaging component for `NW_Portal_Chat` to the footer of every theme layout, so the launcher shows on every page. It doesn't publish; `publish` does, then checks that `/support/` returns HTTP 200. Both stop while `SITE_DOMAIN` still holds `__MY_DOMAIN__`.

Run both, then check the result:

```bash
# Needs NW_Portal_Chat from step 18, adds the component, does not publish
scripts/create-portal.sh messaging

# Publishes, waits for the job, checks that the support page returns HTTP 200
scripts/create-portal.sh publish

# Status Live
sf data query -o $ORG \
  -q "SELECT Id, Name, Status FROM Network WHERE Name='Northwind Support'"

# 200
curl -s -o /dev/null -w '%{http_code}\n' "$SITE_DOMAIN/support/"
```

Read the `messaging` output before you trust these checks. It must print a `patched (1 messaging node(s) in footer)` line for each theme layout that has a footer, followed by the validation and the deploy. If it prints `Embedded Service Deployment 'NW_Portal_Chat' not found ... skipping messaging placement`, it changed nothing. Check the API name with the EmbeddedServiceConfig query in step 18, then run `messaging` and `publish` again.

Then run `echo "$SITE_DOMAIN/support/"` and open that URL in a private browser window. The chat launcher appears at the bottom right after a few seconds, the agent's welcome message appears when you open the chat, and the browser console shows no CSP or CORS errors. `curl` can't see the launcher, because the browser renders it. If you published `NW_Portal_Chat` less than 10 minutes ago, wait before deciding the launcher is missing.

If the script can't place the component, use Builder: Setup > Digital Experiences > All Sites > Builder next to Northwind Support, drag Embedded Messaging into the theme footer, set Deployment to `NW_Portal_Chat` and Hide Chat Button on Load to Default, check the endpoint fields against [experience-portal.md](docs/manual-steps/experience-portal.md) section 6.2, then Publish (section 6.3). If `NW_Portal_Chat` isn't in the Deployment list, it isn't published yet.

### Apply the home page

A new site has the template's default home page. The Northwind page text is in [portal/home/home.html](portal/home/home.html), and [scripts/update-portal-home.py](scripts/update-portal-home.py) writes it into the home view only, together with the page title and description. Deploy that one component, not the whole site bundle: a full bundle deploy would replace the theme layouts with the retrieved copies and could undo the chat component.

The commands use the bundle name `site/Northwind_Support1`, the default for this site. The first line prints the name the portal script found in your org; if it differs, change the two paths that follow.

```bash
cat "$TMPDIR/nw-portal-work/bundle.name"
rm -rf "$TMPDIR/nw-home-single"
sf project retrieve start -o $ORG \
  --metadata "DigitalExperience:site/Northwind_Support1.sfdc_cms__view/home" \
  --target-metadata-dir "$TMPDIR/nw-home-single" --unzip
python3 scripts/update-portal-home.py \
  "$TMPDIR/nw-home-single/unpackaged/unpackaged/digitalExperiences/site/Northwind_Support1"
sf project deploy validate -o $ORG --test-level RunLocalTests \
  --metadata-dir "$TMPDIR/nw-home-single/unpackaged/unpackaged"
sf project deploy start -o $ORG \
  --metadata-dir "$TMPDIR/nw-home-single/unpackaged/unpackaged"
scripts/create-portal.sh publish
```

The live page changes only after the publish. To confirm what the org stored, retrieve the home view again into an empty folder and run the script on it with `--check`; it exits 1 when the stored page differs from `home.html`.

The site-wide `<title>` and meta description are optional; the chat works without them. They live in `sfdc_cms__appPage/mainAppPage`, and the `headMarkup` value in [portal/site/mainAppPage.content.json](portal/site/mainAppPage.content.json) holds the ones used in the reference org. No script in this repository applies that file ([experience-portal.md](docs/manual-steps/experience-portal.md) section 5.3).

![Sites list](docs/demo/30-experience-site.png)

Setup > All Sites: Northwind Support is an active Lightning Web Runtime site, next to the auto-generated chat site.

![Portal home page](docs/demo/01-portal-home.png)

The published home page as a guest, with the Ask Me Anything launcher at the bottom right.

![Chat welcome](docs/demo/03-chat-welcome.png)

The chat open on the portal, with the agent's welcome message.

## Step 20. Set up the specialist's Service Console (runbook step 16)

1. Setup > App Manager > Service Console (LightningService) > Edit > Utility Items (Desktop Only) > Add Utility Item > Omni-Channel > Save.
2. Setup > Object Manager > Messaging Session > Lightning Record Pages. If a page is listed, open the one the Service Console uses and click Edit. If the list is empty, click New, choose Record Page, pick the object Messaging Session and start from the Salesforce default page. In Lightning App Builder, delete the Conversation component, drag Enhanced Conversation from the Components panel into its place and click Save. Then click Activation, assign the page as the org default on the Org Default tab, and save. Without Enhanced Conversation, an accepted chat opens with no conversation pane.
3. App Launcher > Service Console > Omni-Channel utility > set the status to Available - Messaging. If that status isn't listed, run step 13 again and reload the console.

Check the result: the permission set and queue member queries in step 13 return your user.

![Omni-Channel status menu](docs/demo/10-omni-status-menu.png)

The Omni-Channel utility in the Service Console, with Available - Messaging in the status menu.

## Check the whole build

This is runbook step 17. The details and the reasoning behind each expected result are in [docs/TEST_PLAN.md](docs/TEST_PLAN.md).

### Agent tests

Testing Center runs the 18 cases in [specs/Northwind_Service_Agent-testSpec.yaml](specs/Northwind_Service_Agent-testSpec.yaml) against the active agent. `sf agent test create` writes [the test definition file](force-app/main/default/aiEvaluationDefinitions/Northwind_Service_Agent_Tests.aiEvaluationDefinition-meta.xml) and deploys it. Always pass `--test-runner testing-center` to `sf agent test create`; the Agentforce Studio runner rejects this spec format ([TEST_PLAN.md](docs/TEST_PLAN.md) section 2).

```bash
sf agent test create --spec specs/Northwind_Service_Agent-testSpec.yaml \
  --api-name Northwind_Service_Agent_Tests --test-runner testing-center -o $ORG
sf agent test run --api-name Northwind_Service_Agent_Tests \
  --wait 20 --result-format human -o $ORG
sf agent test results --job-id <JOB_ID> --result-format json --verbose \
  --output-dir test-results -o $ORG
```

`<JOB_ID>` is the run ID, which starts with 4KB. Copy it from the Job ID line of the `sf agent test run` output, or open Setup > Quick Find "Testing Center" > Northwind Service Agent Tests (App Launcher > Agentforce Studio > Testing Center in some releases) and copy it from the latest run. Add `--force-overwrite` to `sf agent test create` if you change the spec later.

The results file that lands in `test-results` holds your org's run ID and session IDs, which the committed files have masked. Don't commit it to a public repository, or pass `--output-dir "$TMPDIR/nw-test-results"` instead.

Expected, as in the reference org's last run on version 6: 18 of 18 on topic, 18 of 18 on actions and 17 of 18 on outcome. The escalation cases TC10 to TC12 report the topic `human`, the injection case TC15 reports `Prompt_Injection`, and the one outcome miss is TC11. Testing Center has no live chat, so it can't show the escalation message with the disconnect-power instruction that TC11 expects ([TEST_PLAN.md](docs/TEST_PLAN.md) section 8). Outcome ratings are scored by a model and vary between runs; re-run a failing case once before you change anything.

![Testing Center results](docs/demo/32-testing-center.png)

Northwind Service Agent Tests in Testing Center: subagent and action pass rates of 100% and a response pass rate of 94.44%, 17 of 18. The Agent field reads Version 1 because the test definition doesn't pin a version; each run uses the active agent ([demo.md](demo.md) step 21).

The fact-check spec is optional and deploys nothing: `sf agent test run-eval --spec specs/Northwind_Service_Agent-factChecks-testSpec.yaml --result-format human -o $ORG`.

If you change the document subagents, also run the search check in [TEST_PLAN.md](docs/TEST_PLAN.md) section 6.1: six utterances, each in five new preview sessions, with a `NW_Doc_*` call in every trace.

### Live portal test

Follow [demo.md](demo.md) Parts 1 and 2 (steps 1 to 14). The outline:

1. Log in as the admin, open the Service Console and leave Omni-Channel Offline.
2. Open the URL that `echo "$SITE_DOMAIN/support/"` prints in a private window. The customer must be an anonymous guest.
3. Open the chat and send the demo messages in one conversation: a keyword search, a two-document question, a summary, a detail question, an out-of-docs question and a prompt injection. Wait for each answer, about 10 to 15 seconds. Don't ask two questions the documents can't answer in the same chat: after two misses the agent hands the chat to a specialist.
4. In the Service Console, set Available - Messaging.
5. Report the safety issue from demo.md step 10. The chat arrives in the Omni-Channel inbox; accept it within 60 seconds and reply. The guest sees the specialist join and the reply.
6. End that chat, set the specialist Offline, and in a new private window report smoke from the thermostat again. The escalation message appears, and the MessagingSession query below shows the new session as Waiting, owned by the Northwind Live Support queue (an OwnerId that starts with 00G). Set Available - Messaging, and the chat is offered at once ([TEST_PLAN.md](docs/TEST_PLAN.md) section 7, step 5).

![Incoming chat in Omni-Channel](docs/demo/12-omni-incoming-chat.png)

The escalated chat waiting in the Omni-Channel inbox, with the specialist on Available - Messaging.

Capture the records of the escalated chat:

```bash
sf data query -o $ORG \
  -q "SELECT Id, Status, ChannelType, AgentType, OwnerId, CreatedDate FROM MessagingSession ORDER BY CreatedDate DESC LIMIT 5"
sf data query -o $ORG \
  -q "SELECT Id, WorkItemId, UserId, Status, OriginalQueueId, RoutingType, BotId FROM AgentWork ORDER BY CreatedDate DESC LIMIT 5"
```

The latest session should show channel type EmbeddedMessaging and agent type BotToAgent. Its AgentWork row for the specialist has the `NW_Live_Support` queue as the original queue and routing type QueueBased.

### No open chats

When you finish, end the chat in the private window (chat menu > End chat), end the conversation in the Service Console, set Omni-Channel back to Offline, and check that nothing is left open:

```bash
sf data query -o $ORG \
  -q "SELECT Name, Status FROM MessagingSession WHERE Status IN ('New','Waiting','Active','Inactive','Paused')"
```

Expected: no rows. A leftover waiting session is pushed to the next specialist who goes Available.

## If something goes wrong

| Problem | Fix | Details |
| --- | --- | --- |
| `sf agent adl list` errors in step 4 | Data Cloud provisioning hasn't finished. Wait until Data Cloud Setup shows it complete. | [BUILD_RUNBOOK.md](docs/BUILD_RUNBOOK.md) step 0 |
| A script stops with "EXPECTED_ORG_ID is still the placeholder" or "SITE_DOMAIN is ..." | Set `EXPECTED_ORG_ID` and `MY_DOMAIN` in `config/org-values.local.env`, then reload it (step 2). | [config/org-values.example.env](config/org-values.example.env) |
| The Digital Experiences setting fails to deploy, or Setup returns an internal server error | Data Cloud provisioning was still running. Wait, then deploy again or use the Setup click path. | [experience-portal.md](docs/manual-steps/experience-portal.md) section 4 |
| Prompt template deploy fails with "cannot describe data provider" | The placeholder is still in the files, or the retriever isn't ready. Finish steps 5 and 6. If it still fails once the library is READY and the name is applied, build the three templates in Prompt Builder instead. | [prompt-templates.md](docs/manual-steps/prompt-templates.md) sections 2 and 7 |
| `setup-agent-user.sh` says the Einstein Agent User profile was not found | Agentforce isn't turned on (step 3). | [scripts/setup-agent-user.sh](scripts/setup-agent-user.sh) |
| Assigning `NW_Live_Support_Agent` fails with a license error | The admin lacks the Enhanced Chat User license (`EmbeddedServiceMessagingUserPsl`). Check the seat count and run step 13 again. | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 9 |
| Publish says a template or invocable action doesn't exist | Step 12 isn't complete: the templates aren't deployed or active. | [agent.md](docs/manual-steps/agent.md) section 10 |
| Publish fails with `ERROR_HTTP_404` on the outbound route | The escalation flow isn't active (step 9). If it is, change both connection blocks to the bare name `"NW_Escalate_To_Live_Agent"`, validate and publish again. | [agent.md](docs/manual-steps/agent.md) section 10 |
| Publish fails on the `customer_web_client` surface | Remove the `connection customer_web_client:` block, validate and publish again. | [agent.md](docs/manual-steps/agent.md) section 10 |
| Publish or activate fails with a user or permission error | The username in `default_agent_user` doesn't exist in this org, or the agent user is missing its profile or permission sets. Check that the step 14 `sed` replaced the placeholder, then run step 13 again. | [agent.md](docs/manual-steps/agent.md) section 10 |
| Every answer is "couldn't find" | The retriever isn't ready, or the agent user lacks Data Cloud or prompt template access. Check `sf agent adl status` and add `default` data space access (step 13). If previews work but live answers don't, assign `EinsteinGPTPromptTemplateUser` to the agent user. | [experience-portal.md](docs/manual-steps/experience-portal.md) section 8, [prompt-templates.md](docs/manual-steps/prompt-templates.md) section 6 |
| The chat shows "Agents are not available" when it starts | Check that the agent version is Active (step 14), the channel is active (step 17) and the queue has a routing configuration (`QueueRoutingConfigId` in step 8). | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 9, [DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) section 0.5 |
| New chats go straight to the queue instead of the agent | The inbound flow's agent reference didn't resolve, or the agent isn't active. Check the Route To Northwind Service Agent element (step 16) and the active BotVersion (step 14), then redeploy the flow after `sf agent activate`. | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 4.4 |
| The channel can't be activated | Turn Messaging on, and check that the inbound flow is active and the queue takes Messaging Session work. | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 5 |
| No chat launcher on the portal | Wait 10 seconds and reload. Then check that `NW_Portal_Chat` is published, `create-portal.sh messaging` printed a `patched` line (step 19), the CSP and CORS entries are deployed, and the site was published after the component was added. Look for `Refused to connect` or `Content Security Policy` messages in the browser console. | [experience-portal.md](docs/manual-steps/experience-portal.md) section 7.4 |
| `create-portal.sh messaging` fails because a template route is missing | Add the component in Experience Builder instead (step 19). | [experience-portal.md](docs/manual-steps/experience-portal.md) section 6.4 |
| Guests see the launcher but can't start a chat | Check that the channel's `authMode` is `UnAuth`. Only then look at the deployment's `AreGuestUsersAllowed` flag. | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 9 |
| Available - Messaging is missing in Omni-Channel | `NW_Live_Support_Agent` isn't assigned, or the Omni-Channel utility isn't in the app. Run step 13 again, reload the console. | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 7 |
| The escalated chat waits in the queue | No specialist is Available - Messaging, the 60-second push timed out, or the specialist isn't a queue member. Set the status again; the chat is offered at once. | [DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) section 6 |
| An accepted chat opens with no conversation pane | Put Enhanced Conversation on the Messaging Session record page (step 20). | [escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md) section 7 |
| The portal chat reopens an old conversation | Enhanced Chat keeps it in browser storage. End the chat, or close every private window and open a new one. | [DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) section 6 |
| Testing Center reports a hash-suffixed topic name | Copy the actual value into `expectedTopic` and re-create the test with `--force-overwrite`. | [TEST_PLAN.md](docs/TEST_PLAN.md) section 8 |
| An escalation in `sf agent preview` returns an empty Escalate message and later sends fail | Expected: preview has no messaging session. Test the handoff on the portal. | [README.md](README.md), Known limitations |

## Removing the build

Work in roughly the reverse order of the build. The number in parentheses is the step in this guide that created the item; the runbook step it names has the rollback note. In a new terminal, run the step 2 block first; items 5 and 12 use `$ORG`.

1. Remove the Omni-Channel utility item from the Service Console app, and restore the Messaging Session record page activation you replaced (20).
2. Open Setup > Quick Find "All Sites" > Builder next to Northwind Support, delete the Embedded Messaging component from the theme footer and publish. Then take the site offline: Setup > Quick Find "All Sites" > Workspaces next to Northwind Support > Administration > Settings > Deactivate (19, 18).
3. Delete `NW_Portal_Chat` in Setup > Embedded Service Deployments (18).
4. Deactivate Northwind Web Chat in Setup > Messaging Settings (17), then deactivate the inbound flow (16).
5. Deactivate the agent with `sf agent deactivate --api-name Northwind_Service_Agent -o $ORG --json` (14).
6. Deactivate the agent user in Setup > Users; users can't be deleted. Remove your `NW_Live_Support_Agent` assignment and queue membership (13).
7. Deactivate the three templates in Prompt Builder (12).
8. Delete the `NW_` entries in Setup > Trusted URLs and Setup > CORS (11).
9. Remove the permission set assignments, then delete `NW_Live_Support_Agent` (10). Deactivate `NW_Escalate_To_Live_Agent` (9).
10. Delete the queue, the routing configuration and the presence status, in that order (8).
11. Messaging can be redeployed as `false` only while no channel is active. Digital Experiences stays on (7).
12. Delete the data library only if you are sure. It removes the Data Cloud assets it created and can't be undone. Set `LIB_ID` as in step 5, check that `echo "$LIB_ID"` prints an ID starting with 1JD, read `sf agent adl delete --help`, then run `sf agent adl delete -o $ORG -i "$LIB_ID"` (5).
13. Delete the test definition in Testing Center if you no longer want it (Check the whole build).
14. Put the placeholders back in your local copy. `git status` also lists anything else you changed, such as a new results file in `test-results`.

    ```bash
    git restore force-app/main/default/genAiPromptTemplates \
      force-app/main/default/cspTrustedSites force-app/main/default/corsWhitelistOrigins \
      force-app/main/default/aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent
    git status
    ```

## Where to read more

- [README.md](README.md): architecture, repository layout, prerequisites, org-specific values and known limitations.
- [docs/BUILD_RUNBOOK.md](docs/BUILD_RUNBOOK.md): steps 0 to 17 with verification and rollback.
- [docs/manual-steps/agent.md](docs/manual-steps/agent.md): agent design, publishing, preview and troubleshooting.
- [docs/manual-steps/prompt-templates.md](docs/manual-steps/prompt-templates.md): the templates, the retriever name, versions and the Prompt Builder fallback.
- [docs/manual-steps/escalation-and-chat.md](docs/manual-steps/escalation-and-chat.md): Omni-Channel, the messaging channel, the chat deployment and the specialist workspace.
- [docs/manual-steps/experience-portal.md](docs/manual-steps/experience-portal.md): the portal site, the chat component, guest access and the home page.
- [docs/TEST_PLAN.md](docs/TEST_PLAN.md): test cases, live tests and how to read the results.
- [demo.md](demo.md): the end-to-end walkthrough with screenshots.
- [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md): the presenter script, backup questions and demo troubleshooting.
