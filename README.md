# Northwind Service Agent

Salesforce DX project for an Agentforce Service Agent that supports customers of Northwind Home, a fictitious smart-home retailer. Customers chat with the agent on the Northwind Support Experience Cloud site. The agent answers questions, summarizes policies and pulls out specific details from four company documents (warranty, returns and refunds, the Aura Smart Thermostat T200 manual, and CarePlus service plans). When a customer asks for a person, reports a safety problem or needs a policy exception, the agent hands the chat to a live specialist through Omni-Channel.

The reference build runs in a Developer Edition org with the CLI alias `northwind-dev`, and its portal is at `https://<my-domain>.my.site.com/support/`. Values that identify that org are masked in this repository; see [Org-specific values](#org-specific-values).

To see the build working, start with [demo.md](demo.md): the end-to-end demo with a screenshot for every step. To set it up in your own org, follow [SETUP_GUIDE.md](SETUP_GUIDE.md), a point-and-click guide that uses only Salesforce Setup and the builders, with no command line or code (also available as [SETUP_GUIDE.docx](SETUP_GUIDE.docx)).

## Architecture

The four PDFs in `docs/pdf` are loaded into an Agentforce Data Library, `Northwind_Home_Docs`. Creating the library provisions the Data Cloud pipeline behind it: an unstructured data lake object and data model object, a hybrid (vector plus keyword) search index that splits each PDF into chunks of up to 512 tokens, and a retriever.

Three Flex prompt templates, `NW_Doc_Answer_Question`, `NW_Doc_Summarize` and `NW_Doc_Extract_Details`, query that retriever and ask the model to answer only from the returned chunks, with citations. If nothing relevant comes back they return a fixed "couldn't find" sentence.

The agent is written in Agent Script (`Northwind_Service_Agent.agent`); version 6 is active in the reference org. A router sends each customer message to one of six subagents: `document_qa`, `document_summary` and `detail_finder` each use one prompt template, `escalation` hands off to a person, and `off_topic` and `ambiguous_question` redirect or ask for more detail. The document subagents search on every turn. Before the search, the model's only job is to rewrite the customer's message as a search query. The agent script then runs the subagent's prompt template with that query, and the model writes the reply from the template's response (`docs/manual-steps/agent.md` section 1.3). The agent does not read CRM records.

On the portal, the Embedded Messaging component (deployment `NW_Portal_Chat`) opens a session on the Enhanced Chat channel `NW_Web_Chat`. The channel's Omni-Channel flow `NW_Route_Messaging_To_Agent` gives new sessions to the agent, with queue `NW_Live_Support` as the fallback. On escalation the agent records a short summary for the specialist and runs the outbound flow `NW_Escalate_To_Live_Agent`, which routes the session to queue `NW_Live_Support`, where it waits for the next available specialist. The specialist picks it up in the Service Console with the full transcript.

## Repository layout

```
SETUP_GUIDE.md / .docx         Step-by-step setup in a new org
demo.md                        End-to-end demo with screenshots
force-app/main/default/
  aiAuthoringBundles/          Agent Script bundle for Northwind_Service_Agent
  aiEvaluationDefinitions/     Testing Center test definition (generated from specs/)
  genAiPromptTemplates/        The three NW_Doc_* Flex prompt templates
  flows/                       Inbound (agent routing) and outbound (escalation) Omni-Channel flows
  messagingChannels/           NW_Web_Chat Enhanced Chat channel
  queues/ queueRoutingConfigs/ servicePresenceStatuses/ permissionsets/
                               Live support queue, routing, presence status and specialist access
  cspTrustedSites/ corsWhitelistOrigins/
                               Trusted URLs and CORS entries for the portal and chat runtime
  settings/                    Omni-Channel, Messaging, Digital Experiences settings
docs/
  BUILD_RUNBOOK.md             Ordered build steps with verification and rollback
  TEST_PLAN.md                 Automated and live tests, expected results
  DEMO_SCRIPT.md               Presenter script for a live demo
  demo/                        Screenshots used in demo.md
  manual-steps/                Detail per area: agent, prompt templates, escalation and chat, portal
  evidence/                    Delivery record, data library and search index exports
  source/                      Document text (Markdown)
  pdf/                         PDFs built from docs/source for upload to the data library
portal/                        Home page HTML and site title/meta for the Northwind Support site
scripts/                       Setup scripts (data library, agent user, portal, home page, PDF build)
specs/                         Agent test specs (main suite and optional fact checks)
test-results/                  JSON results of the Testing Center runs
```

## Prerequisites

- An org with Agentforce, Data Cloud, Service Cloud with Omni-Channel and Messaging for In-App and Web, and Digital Experiences. Data Cloud provisioning must be complete before the data library can be created. The reference org is a Developer Edition org on API 67.0; the project `sourceApiVersion` is 66.0.
- Licenses for the Einstein Agent user (`AgentforceServiceAgentUserPsl`, `GenieDataPlatformStarterPsl`) and for the specialist (`ServiceUserPsl`, `EmbeddedServiceMessagingUserPsl`).
- A deploying admin with the Prompt Template Manager permission set (`EinsteinGPTPromptTemplateManager`).
- Salesforce CLI with the agent plugin. The build used `@salesforce/cli` 2.106.6 and `plugin-agent` 2.1.1.
- `python3` and `curl` for the scripts, `xmllint` for the template checks. `scripts/build_docs.py` also needs the `reportlab` Python package, but only if you rebuild the PDFs.

## Deploying to a new org

To build it by point and click in Setup and the builders, with no command line, use [SETUP_GUIDE.md](SETUP_GUIDE.md), which walks through every screen from turning on Agentforce to the live chat test. To deploy from this repository with the Salesforce CLI, follow [docs/BUILD_RUNBOOK.md](docs/BUILD_RUNBOOK.md), which has verification and rollback for every step. In outline:

1. Authenticate the org, fill in `config/org-values.local.env` (below) and confirm Data Cloud provisioning has finished.
2. Create the data library from the PDFs in `docs/pdf` and wait for the retriever.
3. Put the new retriever API name into the three prompt templates.
4. Deploy the Omni-Channel and Messaging settings, queue, routing, escalation flow and permission set, set your domain in the CSP and CORS entries and deploy them, then deploy the prompt templates.
5. Create the agent user, set it in the `.agent` file, then validate, publish and activate the agent.
6. Deploy the inbound flow and the messaging channel, activate the channel, and create the `NW_Portal_Chat` embedded service deployment.
7. Activate the portal, add the chat component, publish, and set up the specialist's Service Console.
8. Run the agent tests and an end-to-end chat.

## Org-specific values

Files that depend on the org hold a placeholder instead of a value. Replace each one before you deploy the files that contain it: a file that still holds a placeholder either fails to deploy or leaves a setting that doesn't work.

| Placeholder | Files | Replace with | Runbook step |
| --- | --- | --- | --- |
| `__RETRIEVER_API_NAME__` | The three `NW_Doc_*` files in `genAiPromptTemplates/` | The data library retriever's API name, read in Prompt Builder. `scripts/setup-data-library.sh apply` writes it | 2 |
| `__MY_DOMAIN__` | `NW_Portal_Site_Domain` and `NW_Messaging_SCRT` in `cspTrustedSites/`, `NW_Portal_Site_Origin` and `NW_Messaging_SCRT_Origin` in `corsWhitelistOrigins/` | Your My Domain name: the host of the org URL without `.my.salesforce.com`, for example `acme-dev-ed.develop` | 7 |
| `__AGENT_USER_USERNAME__` | `aiAuthoringBundles/Northwind_Service_Agent/Northwind_Service_Agent.agent` | The agent user's username, the last line printed by `scripts/setup-agent-user.sh` | 10 |

The scripts take the target org from environment variables:

| Variable | Read by | Default |
| --- | --- | --- |
| `TARGET_ORG` | `setup-data-library.sh`, `setup-agent-user.sh` (or its first argument) | `northwind-dev` |
| `ORG_ALIAS` | `create-portal.sh` | `northwind-dev` |
| `EXPECTED_ORG_ID` | all three scripts. When set, a script stops if the alias points to a different org | Empty, so the org ID is not checked |
| `SITE_DOMAIN` | `create-portal.sh` | `https://__MY_DOMAIN__.my.site.com`. The `messaging`, `publish` and `all` steps stop until it is set |
| `RETRIEVER_API_NAME` | `setup-data-library.sh resolve` and `apply` | Empty, so `resolve` looks it up |

`config/org-values.example.env` lists all of these with a comment for each. Copy it, fill it in, and load it in every shell you run the build from:

```bash
cp config/org-values.example.env config/org-values.local.env    # git ignores config/*.local.env
set -a; . config/org-values.local.env; set +a
grep -rnE "__[A-Z][A-Z_]*__" force-app                          # placeholders not yet replaced
```

Replacing the placeholders writes your org's values into tracked files. Don't commit those changes to a public repository; `git restore` on the changed files puts the placeholders back.

In the documentation, values from the reference org are masked. Record IDs keep their three-character key prefix followed by X's (for example `1JDXXXXXXXXXXXXXXX`), and names appear as `<org-id>`, `<my-domain>`, `<admin-username>`, `<agent-user-username>` and `File_Northwind_Home_Docs_1Cx_<suffix>`. The admin's name appears as Admin User. Commands that need an ID from your org use a placeholder such as `<library-id>`.

## Running tests

Agent tests run in Testing Center against the published, active agent. From the project root:

```bash
sf agent test create --spec specs/Northwind_Service_Agent-testSpec.yaml \
  --api-name Northwind_Service_Agent_Tests --test-runner testing-center -o northwind-dev
sf agent test run --api-name Northwind_Service_Agent_Tests --wait 20 --result-format human -o northwind-dev
sf agent test results --job-id <JOB_ID> --result-format json --verbose --output-dir test-results -o northwind-dev
```

Add `--force-overwrite` to `sf agent test create` after changing the spec. The optional fact-check spec runs without deploying anything:

```bash
sf agent test run-eval --spec specs/Northwind_Service_Agent-factChecks-testSpec.yaml --result-format human -o northwind-dev
```

The main suite has 18 cases. On agent version 6 the latest run (September 15, 2026) passed 18 of 18 on topic, 18 of 18 on actions and 17 of 18 on outcome; the one miss is explained in the test plan. A separate preview check of the six phrasings most likely to skip the search found a prompt template call in all 30 sessions (`docs/TEST_PLAN.md` section 6.1). Escalation to a real person can only be tested through the portal chat. [docs/TEST_PLAN.md](docs/TEST_PLAN.md) covers the cases, the live tests and how to read the results.

This project has no Apex or Lightning web components. The `npm` scripts and Jest configuration are the standard SFDX project template and are not used.

## Known limitations

- Testing Center and `sf agent preview` sessions have no messaging session, so the handoff to a person can't complete there. In CLI preview the escalation turn returns an Escalate message with no text and no trace, and any later send in that session fails. Testing Center records the turn only as "User requested escalation to human." The transfer itself was tested in the live portal chat.
- The safety case (TC11) fails its outcome check in Testing Center for a known reason; see `docs/TEST_PLAN.md` section 8.
- The agent hands over after two unanswered questions. Deciding that an answer was "not found" is left to the model, because Agent Script has no substring test. The count covers the whole conversation, not each question.
- The embedded service deployment `NW_Portal_Chat` cannot be deployed as metadata. It is created in Setup or through the Connect API. The Omni-Channel utility in the Service Console and the Enhanced Conversation component on the Messaging Session page are also set in Setup.
- The Experience Cloud site itself is not in source. `scripts/create-portal.sh` creates and configures it, and `scripts/update-portal-home.py` applies the home page content.
- Published prompt template versions cannot be edited. Changing a template's prompt means adding a new version (see `docs/manual-steps/prompt-templates.md`).
- Guest visitors can ask about anything in the data library, so it must only hold public content. Citation links to Salesforce-hosted files may not open for guests; the answers also name the source document in the text.
- Live specialists work to the business hours in the CarePlus document, but no business hours are configured on the channel. Outside those hours an escalated chat waits in the queue until someone goes online.
