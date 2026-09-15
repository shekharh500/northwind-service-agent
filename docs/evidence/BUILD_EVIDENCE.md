# Northwind Service Agent: Delivery Record

| | |
| --- | --- |
| Org | `northwind-dev` (`<org-id>`), `https://<my-domain>.my.salesforce.com` |
| Portal | `https://<my-domain>.my.site.com/support/` |
| Built | September 14 and 15, 2026 |
| Agent | `Northwind_Service_Agent`, version 6 active |
| Dates and times | India Standard Time (IST). Setup shows record times in the viewer's time zone. The org's users are on Pacific time, where anything before 12:30 p.m. IST falls on the previous day |

What was delivered against each requirement, and the evidence for it. Build steps are in `docs/BUILD_RUNBOOK.md` and the test approach in `docs/TEST_PLAN.md`.

Record IDs and org-specific values are masked in this record. IDs keep their three-character key prefix followed by X's, so `4KBXXXXXXXXXXXXXXX` is a test run and `0AfXXXXXXXXXXXXXXX` a deploy. The org ID, domain, usernames and retriever suffix appear as placeholders such as `<my-domain>`, and the admin appears as Admin User.

## Requirements

| ID | Requirement | Delivered in the org | How to demonstrate |
|---|---|---|---|
| REQ-01 | Retrieval through Data Cloud | Agentforce Data Library `Northwind_Home_Docs` (`1JDXXXXXXXXXXXXXXX`), which created data lake object `ADL_Northwind_Home__dll`, data model object `ADL_Northwind_Home__dlm`, search index `ADL_Northwind_Home` and retriever `File_Northwind_Home_Docs_1Cx_<suffix>` | Setup > Agentforce Data Library; Data Cloud app > Search Index; `search-index.json` in this folder |
| REQ-02 | Answers, summaries and specific details from unstructured documents, from a question or keywords | Only the four PDFs (warranty, returns and refunds, T200 manual, CarePlus service levels); no CRM lookups in the agent; subagents `document_qa`, `document_summary` and `detail_finder`, each of which runs its prompt template on every turn | Portal chat or `sf agent preview`. Ask for something the documents don't contain, such as the Halo Video Doorbell price, and the agent says it can't find it |
| REQ-03 | Document chunking and grounded responses | Hybrid (vector and keyword) search index; PDFs split with section-aware chunking, 512 tokens maximum; `e5_large_v2` embeddings (1024 dimensions), HNSW index, cosine similarity; chunk object `ADL_Northwind_Home_chunk__dlm`, vector object `ADL_Northwind_Home_index__dlm`. The templates insert `{!$EinsteinSearch:File_Northwind_Home_Docs_1Cx_<suffix>.results}` into the prompt | `search-index.json` (`chunkingConfiguration`, `vectorEmbeddingConfiguration`); Prompt Builder preview, Resolution tab |
| REQ-04 | Prompt templates for each response type | Active Flex templates `NW_Doc_Answer_Question` (Northwind - Answer Question), `NW_Doc_Summarize` (Northwind - Summarize Topic) and `NW_Doc_Extract_Details` (Northwind - Extract Details), each grounded on the retriever, with citations and a fixed "couldn't find" sentence | Setup > Prompt Builder. Tested through the generations API: a 36-month warranty answer, a refusal for the doorbell price, and the list of error codes E1 to E6 |
| REQ-05 | Subagent routing | Agent Script agent with a router and six subagents: `document_qa`, `document_summary`, `detail_finder`, `escalation`, `off_topic`, `ambiguous_question` | Agentforce Builder; routing trace from `sf agent trace read` |
| REQ-06 | Handoff to a live specialist | `@utils.escalate` runs outbound Omni-Channel flow `NW_Escalate_To_Live_Agent`, which routes every escalated chat to queue `NW_Live_Support` (routing configuration `NW_Messaging_Routing`, presence status Available - Messaging), where it waits for the next available specialist. The specialist works in the Service Console with the Omni-Channel utility and Enhanced Conversation on the Messaging Session page | Live chat on the portal (see Live end-to-end check). First confirmed on September 14 in MessagingSession MS-00000001: a guest asked for a person, the chat was routed through the queue to the admin, and the guest saw "Admin U joined" |
| REQ-07 | Agent on the Experience Cloud customer portal | Experience Cloud LWR site Northwind Support (Live) with the Embedded Messaging component; Enhanced Chat channel `NW_Web_Chat` (active, session handler flow `NW_Route_Messaging_To_Agent`, fallback queue `NW_Live_Support`); embedded service deployment `NW_Portal_Chat` (Web, WebV2) | Open the portal as a guest and start the chat |

## Documents in the data library

The library was first loaded on September 14, 2026, with the first edition of the four PDFs. On September 15 they were replaced with the second edition now in `docs/pdf`, which has the same document numbers and facts as the first edition in a new layout. The replacement used the procedure in runbook step 1 (`sf agent adl file delete`, then `sf agent adl file add`), and the library re-indexed the same day. Later that day the returns policy and CarePlus PDFs were replaced a second time after minor wording edits; the sizes below are those files. The search index, the retriever and the prompt templates did not change.

Library contents after the replacement:

| File | File reference | Size (bytes) | Status |
| --- | --- | --- | --- |
| `01-warranty-policy.pdf` | `1JcXXXXXXXXXXXXXXX` | 70,514 | INDEXED |
| `02-returns-refunds-policy.pdf` | `1JcXXXXXXXXXXXXXXX` | 68,616 | INDEXED |
| `03-aura-thermostat-t200-manual.pdf` | `1JcXXXXXXXXXXXXXXX` | 71,456 | INDEXED |
| `04-careplus-service-plans-sla.pdf` | `1JcXXXXXXXXXXXXXXX` | 68,462 | INDEXED |

Each size matches the file in `docs/pdf`; the first-edition PDFs were 5,128 to 6,063 bytes. Three files have new references created on September 15. The warranty policy kept its September 14 reference: its delete returned "We couldn't delete your file. Try again.", and after `file add` the same reference shows the second-edition file's size and INDEXED, with that error message still attached.

`data-library.json` and `search-index.json` in this folder were exported again on September 15, and `data-library.json` again after the second replacement, so they list the current file references and index settings.

## Agent test history

Testing Center suite `Northwind_Service_Agent_Tests`, 18 cases. Raw results are in `test-results/`.

| Run | Results file | Agent version | Topic | Actions | Outcome | Notes |
|---|---|---|---|---|---|---|
| `4KBXXXXXXXXXXXXXXX` | `northwind-run2.json` | 1 | 13/18 | 17/18 | 17/18 | Five topic mismatches: escalations report the platform topic `human` (TC10 to TC12), the injection attempt was stopped by the platform `Prompt_Injection` guardrail (TC15), and a two-fact question (TC04) went to `detail_finder` |
| `4KBXXXXXXXXXXXXXXX` | `northwind-run3.json` | 1 | 18/18 | 17/18 | 17/18 | Spec updated to the platform topic names. TC17 (keyword-only query) replied "I will check..." without calling the action |
| `4KBXXXXXXXXXXXXXXX` | `northwind-run4-v2.json` | 2 | 18/18 | 18/18 | 18/18 | `document_qa` instructions tightened for keyword-only queries. Coherence 13/13, completeness 11/11 |
| `4KBXXXXXXXXXXXXXXX` | `northwind-run5-v3.json` | 3 | 18/18 | 17/18 | 17/18 | Template outputs set to `is_displayable: False`, so the portal shows one reply per answer instead of the raw action output plus the agent's restatement. TC17 missed again: the agent asked which product before searching |
| `4KBXXXXXXXXXXXXXXX` | `northwind-run6-v4.json` | 4 | 18/18 | 18/18 | 17/18 | "Search first, clarify later" rule added; TC17 then passed, and answered in 5 of 5 preview runs. Only miss: TC11 outcome |
| `4KBXXXXXXXXXXXXXXX` | `northwind-run7-v4.json` | 4 | 18/18 | 18/18 | 17/18 | Repeat run with the same result. Coherence 13/13, completeness 11/11 |
| `4KBXXXXXXXXXXXXXXX` | `northwind-run8-v6.json` | 6 | 18/18 | 18/18 | 17/18 | Mandatory search design; test definition re-created from the current spec before the run. Only miss: TC11 outcome. Coherence 13/13, completeness 11/11 |

Version 5 introduced the mandatory search design and was not run through Testing Center on its own. Version 6 has the same behavior with updated comments in the `.agent` file.

Version 5 was published because version 4, although it passed the suite, sometimes told the customer the documents didn't cover a question without running its prompt template. The figures and the design change are in `docs/manual-steps/agent.md` section 1.3.

### Mandatory search re-check (September 15, 2026, agent version 6)

The six phrasings most likely to skip the search, each sent in five new `sf agent preview` sessions. A session counts as searched when its trace shows a prompt template call.

| Utterance | Sessions that searched |
| --- | --- |
| "warranty transfer to a new owner" | 5/5 |
| "Will the warranty cover my Aura T200 if it got damaged after I wired it to a 240V baseboard heater?" | 5/5 |
| "Is the Aura T200 compatible with a 240V baseboard heater, and if I already wired it that way and it broke, will the warranty cover it?" | 5/5 |
| "How much does the Halo Video Doorbell cost?" | 5/5 |
| "Can you summarize the Northwind Home returns and refunds policy for me?" | 5/5 |
| "What are the exact refund timelines after I send a return back? Break it down by payment method." | 5/5 |

All 30 sessions searched. The procedure is in `docs/TEST_PLAN.md` section 6.1.

The remaining miss on versions 4 and 6 is the TC11 outcome rating. The reason is in `docs/TEST_PLAN.md` section 8, item 2.

## Live end-to-end check (September 15, 2026, agent version 4)

1. A guest on the portal home page asked "Does the T200 work with 5 GHz Wi-Fi?" and got a single answer citing the T200 manual.
2. The guest asked "What's the difference between CarePlus Basic and Premium?" and got one structured summary with its source.
3. In a new conversation with no specialist online, the guest reported smoke and a burning smell. The agent showed the escalation message with the disconnect-power instruction, the chat showed "Transferring...", and MessagingSession `MS-00000002` was Waiting, owned by queue Northwind Live Support.
4. The specialist went Available - Messaging in the Service Console. The queued chat was offered straight away and accepted, and the specialist's reply appeared in the guest's chat ("Admin U joined").

The records for steps 3 and 4: MessagingSession `0MwXXXXXXXXXXXXXXX` (MS-00000002, created at 12:50 a.m. IST, which Salesforce stores as 19:20 UTC on September 14; channel type EmbeddedMessaging, agent type BotToAgent) and AgentWork `0BzXXXXXXXXXXXXXXX` (QueueBased, original queue `NW_Live_Support`, accepted by the specialist at 12:53 a.m. IST).

The escalation flow changed during the build. The first version of `NW_Escalate_To_Live_Agent` routed only when a specialist was online and otherwise ended without routing. The guest then saw "Agents are not available. Try again later." while the agent said it was connecting them. For this check, flow version 2 was active: it still checked availability, but both outcomes routed to `NW_Live_Support`. Version 3, active since September 15, drops the check. It finds the queue and routes the chat there, so a Priority 1 safety chat always reaches the queue and waits for the next available specialist.

## Live end-to-end checks on agent version 6 (September 15, 2026, escalation flow version 3)

With the specialist Available - Messaging, a guest opened a new chat on the redesigned home page and sent `warranty transfer rules`. The agent searched and answered from the warranty policy with its citation. The guest then reported smoke and a burning smell. The chat showed the escalation message with the disconnect-power instruction, the agent left, and the transfer went to Northwind Live Support. The specialist accepted it in the Service Console and replied, and the reply appeared in the guest's chat.

Records: MessagingSession `0MwXXXXXXXXXXXXXXX` (MS-00000003, created 8:17 a.m. IST), AgentWork `0BzXXXXXXXXXXXXXXX` (inbound routing, closed) and `0BzXXXXXXXXXXXXXXX` (QueueBased, original queue `NW_Live_Support`, accepted by Admin User at 8:19 a.m. IST). The chat was ended by the specialist afterward.

The same check was repeated on the current build, after the home page edit and the second replacement of the returns and CarePlus PDFs, while the screenshots in `docs/demo` were taken. The guest asked the questions shown in `demo.md` steps 3 to 8, then reported smoke; the chat went to Northwind Live Support, the specialist accepted it and replied. Records: MessagingSession MS-00000005 (created 11:15 a.m. IST, agent type BotToAgent, channel type EmbeddedMessaging) and AgentWork `0BzXXXXXXXXXXXXXXX` (QueueBased, original queue `NW_Live_Support`, accepted at 11:26 a.m. IST). Testing Center run `4KBXXXXXXXXXXXXXXX` and the CLI preview checks in `docs/TEST_PLAN.md` ran before the second PDF replacement.

## Portal home page

- Source: `portal/home/home.html`, applied with `scripts/update-portal-home.py <bundle-site-dir>` to `sfdc_cms__view/home` only. The script can be re-run and has a `--check` mode.
- Deployed as the single component `DigitalExperience site/Northwind_Support1.sfdc_cms__view/home` rather than the whole bundle, so the 26 other site components were not overwritten.
- The first version of the page was published on September 15, 2026, and checked in a guest browser at 1280 px and 375 px wide: no horizontal scrolling, one H1, and the chat launcher does not cover the footer. The chat answered one of the page's example questions with a citation.
- The redesigned page in `portal/home/home.html` was deployed and published later on September 15. Its layout is in `docs/manual-steps/experience-portal.md` section 5.3.
- The site `<title>` changed from the template default "Welcome to LWC Communities!" to "Northwind Home Support", with a meta description, in `sfdc_cms__appPage/mainAppPage` (copy in `portal/site/mainAppPage.content.json`). Confirmed in the server-rendered HTML.

## Validation before deployment

| Deploy ID | Scope | Result |
| --- | --- | --- |
| `0AfXXXXXXXXXXXXXXX` | All 15 components other than the prompt templates and the agent bundle (settings, Omni-Channel, both flows, channel, permission set, CSP and CORS) | Succeeded, 0 errors, 10 local tests run |
| `0AfXXXXXXXXXXXXXXX`, `0AfXXXXXXXXXXXXXXX` | Omni-Channel components, both flows, messaging channel, permission set | Succeeded |
| `0AfXXXXXXXXXXXXXXX` | Messaging setting (`enableLiveMessage` true) | Succeeded |
| `0AfXXXXXXXXXXXXXXX`, `0AfXXXXXXXXXXXXXXX` | Digital Experiences settings, CSP and CORS | Succeeded |
| `0AfXXXXXXXXXXXXXXX` | Site activation (Network status Live) | Succeeded |
| `0AfXXXXXXXXXXXXXXX` | Site bundle with the Embedded Messaging component in both theme layouts | Succeeded, 27 components |

All check-only runs used `--test-level RunLocalTests`. `sf agent validate authoring-bundle --api-name Northwind_Service_Agent` returned success with no warnings before the first publish.

## Configuration outside the deployable metadata

Made in Setup:

- Agentforce turned on (Setup > Agentforce Agents).
- Data Cloud provisioned (Data Cloud Setup Home > Get Started).
- Digital Experiences enabled.
- Enhanced Chat terms accepted and `NW_Web_Chat` activated.
- Omni-Channel utility added to the Service Console app.
- Messaging Session record page: the classic Conversation component replaced with Enhanced Conversation, activated as the org default.

Created as org data or through the CLI rather than from `force-app` (runbook step in brackets):

- Data library `Northwind_Home_Docs`, loaded on September 14, 2026, with the first edition of the four PDFs, and updated on September 15 with the second edition from `docs/pdf` (1). See Documents in the data library.
- Einstein Agent user `<agent-user-username>`, its licenses and permission sets, the admin's specialist licenses and permission set, and the admin's `NW_Live_Support` membership (9; re-run after any queue redeploy).
- Agent published and activated; six versions, version 6 active (10). The version history is in `docs/manual-steps/agent.md` section 1.6.
- Embedded service deployment `NW_Portal_Chat` and its generated `ESW_NW_Portal_Chat_*` sites (14).
- Northwind Support site: created, activated, chat component added, home page and title applied, published (15).
- Testing Center definition `Northwind_Service_Agent_Tests`, re-created from `specs/Northwind_Service_Agent-testSpec.yaml` on September 15 (17).

## Changes deployed on September 15, 2026

- Documents: the second edition of the PDFs replaced the first in `Northwind_Home_Docs` and was re-indexed.
- Agent: versions 5 and 6 published, version 6 active. Version 6 is published from the `.agent` file in this repository, so the mandatory search design, the welcome, error and escalation messages, and the subagent and action labels and descriptions in source are all live.
- Prompt templates: labels changed to Northwind - Answer Question, Northwind - Summarize Topic and Northwind - Extract Details, and descriptions updated. Template text and version identifiers stayed the same.
- Flows: `NW_Escalate_To_Live_Agent` version 3 is active. It finds the `NW_Live_Support` queue and routes the chat to it.
- Descriptions updated on both flows, queue `NW_Live_Support`, messaging channel `NW_Web_Chat` (active), permission set `NW_Live_Support_Agent` and both Trusted URLs.
- Portal home page: the redesigned `portal/home/home.html`, deployed and published.
- Test definition `Northwind_Service_Agent_Tests`: re-created from the current spec, then run on version 6 (run `4KBXXXXXXXXXXXXXXX`). The only spec changes were in expected outcomes: TC02, TC04, TC06 and TC07 now write amounts, percentages and dates as the documents do ($, %, month-first dates), and TC11 no longer says "verified in the live portal chat". No expected facts changed.
