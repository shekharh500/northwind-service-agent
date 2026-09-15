# Escalation to a Live Agent and Enhanced Chat

When a customer asks for a person, reports a safety problem or needs a policy exception, the agent hands the chat to a specialist through Omni-Channel. The same Enhanced Chat channel carries portal conversations to the agent and escalated conversations to the specialist. The deploy commands are in runbook steps 3 to 6, 9 and 12 to 16, and the portal side is in `experience-portal.md`. For the parts the Metadata API can't handle, the Setup click path is given instead.

The reference org is `northwind-dev` (Developer Edition, API 67.0); the project `sourceApiVersion` is 66.0.

## 1. Message path

1. A visitor opens the chat on `https://<my-domain>.my.site.com/support`. The Embedded Messaging component uses the embedded service deployment `NW_Portal_Chat`.
2. The session starts on messaging channel `NW_Web_Chat` (EmbeddedMessaging, routed by an Omni-Channel flow). The channel's session handler flow is `NW_Route_Messaging_To_Agent` and its fallback queue is `NW_Live_Support`.
3. `NW_Route_Messaging_To_Agent` (RoutingFlow) looks up the `NW_Live_Support` queue and routes the session with routing type Copilot to the agent `Northwind_Service_Agent`, with that queue as the fallback.
4. The agent runs as the Einstein Agent user. When a handoff is needed, the `escalation` subagent calls `@utils.escalate`. The `connection messaging` and `connection customer_web_client` blocks give the outbound route: type `OmniChannelFlow`, name `flow://NW_Escalate_To_Live_Agent`.
5. `NW_Escalate_To_Live_Agent` (RoutingFlow) has two elements: Get Live Support Queue finds `NW_Live_Support` by developer name, and Route To Live Support Queue routes the session there with QueueBased routing. It does not check whether anyone is online. When nobody is, the session waits in the queue (MessagingSession status Waiting) and is offered as soon as a specialist becomes available.
6. Queue `NW_Live_Support` handles MessagingSession work with routing configuration `NW_Messaging_Routing`. The specialist (the admin in the reference org) accepts the work in the Service Console with Omni-Channel status Available - Messaging, which the permission set `NW_Live_Support_Agent` grants.

The conversation stays in the same MessagingSession throughout, so the specialist sees the whole agent transcript.

In the reference org, version 3 of `NW_Escalate_To_Live_Agent` has been active since September 15, 2026, deployed from the file in source. Versions 1 and 2 first checked whether a specialist was online. Version 1 ended without routing when nobody was, so the guest saw "Agents are not available. Try again later." while the agent said it was connecting them. Version 2 sent both outcomes to the queue, and version 3 removed the check.

## 2. Components

| Component | Path | Deployable as metadata |
|---|---|---|
| OmniChannelSettings (Omni-Channel on; skills routing and status-based capacity off) | `force-app/main/default/settings/OmniChannel.settings-meta.xml` | Yes |
| LiveMessageSettings (Messaging on) | `force-app/main/default/settings/LiveMessage.settings-meta.xml` | Yes |
| ServicePresenceStatus `NW_Available_Messaging`, label "Available - Messaging" (channel `sfdc_livemessage`) | `force-app/main/default/servicePresenceStatuses/` | Yes |
| QueueRoutingConfig `NW_Messaging_Routing` (Most Available, priority 1, weight 1, 60-second push timeout) | `force-app/main/default/queueRoutingConfigs/` | Yes |
| Queue `NW_Live_Support` ("Northwind Live Support", MessagingSession) | `force-app/main/default/queues/` | Yes |
| Flow `NW_Escalate_To_Live_Agent` (outbound, QueueBased; queue lookup and Route Work) | `force-app/main/default/flows/` | Yes |
| Flow `NW_Route_Messaging_To_Agent` (inbound, Copilot routing) | `force-app/main/default/flows/` | Yes, after the agent is published (4.4) |
| PermissionSet `NW_Live_Support_Agent` | `force-app/main/default/permissionsets/` | Yes |
| MessagingChannel `NW_Web_Chat` ("Northwind Web Chat", Enhanced Chat, `UnAuth`) | `force-app/main/default/messagingChannels/` | Yes; activation is a separate step |
| Embedded service deployment `NW_Portal_Chat` | not in source | No; created in Setup or with the Connect API (section 6) |
| Einstein Agent user, license and permission set assignments, queue membership | `scripts/setup-agent-user.sh` | Data, not metadata |

There is no presence configuration or embedded service configuration in source. Users without a specific presence configuration get the org's `default_presence_config` (capacity 5).

The components can be checked without deploying:

```bash
sf project deploy validate -o northwind-dev --test-level RunLocalTests --wait 30 \
  --source-dir force-app/main/default/settings/OmniChannel.settings-meta.xml \
  --source-dir force-app/main/default/servicePresenceStatuses \
  --source-dir force-app/main/default/queueRoutingConfigs \
  --source-dir force-app/main/default/queues \
  --source-dir force-app/main/default/flows/NW_Escalate_To_Live_Agent.flow-meta.xml \
  --source-dir force-app/main/default/flows/NW_Route_Messaging_To_Agent.flow-meta.xml \
  --source-dir force-app/main/default/messagingChannels \
  --source-dir force-app/main/default/permissionsets/NW_Live_Support_Agent.permissionset-meta.xml
```

`sf project deploy validate` in CLI 2.106.6 rejects `--test-level NoTestRun`. With `RunLocalTests` the only local tests are the 10 standard site controller test classes that Digital Experiences adds to the org.

## 3. Org prerequisites

- Omni-Channel is enabled. The settings file keeps `enableOmniChannel=true` with the other four flags false, which matches the reference org.
- The standard service channel `sfdc_livemessage` (label Messaging, MessagingSession) exists.
- Messaging is on. It was off in the reference org; `LiveMessage.settings` turns it on (5.1).
- Profile `Einstein Agent User` (Einstein Agent license) exists.
- Permission set licenses: `AgentforceServiceAgentUserPsl`, `GenieDataPlatformStarterPsl` (Data Cloud), `EmbeddedServiceMessagingUserPsl` (Enhanced Chat User), `LiveMessageUserPsl` (Messaging User), `ServiceUserPsl` (Service Cloud User). The reference org has 200, 11 and 6 seats of the Agentforce, Enhanced Chat and Messaging licenses.
- The Enhanced Chat User license grants `EmbeddedMessagingAgent` and `LMEndMessagingSessionUserPerm`, the two user permissions in `NW_Live_Support_Agent`.
- The standard `AgentforceServiceAgentUser` permission set includes Execute Prompt Templates, so the agent user doesn't need `EinsteinGPTPromptTemplateUser`.
- Digital Experiences is enabled and the Northwind Support site exists before the embedded service deployment is created (`experience-portal.md`).

## 4. Deployment order

The dependencies set the order: queue and escalation flow before the agent is published, the agent before the inbound flow, the inbound flow before the channel, and the channel before the embedded service deployment.

### 4.1 Omni-Channel foundation

Runbook steps 3 to 6 deploy the settings, presence status, routing configuration, queue, outbound flow and permission set, with a query for each. Before going further, `QueueRoutingConfigId` on the `NW_Live_Support` queue and `ActiveVersionId` on `NW_Escalate_To_Live_Agent` must both be non-null.

### 4.2 Users, licenses and queue membership

Run `scripts/setup-agent-user.sh` after 4.1 (runbook step 9), because it assigns `NW_Live_Support_Agent` and adds the admin to `NW_Live_Support`. It checks before each change, so it is safe to re-run:

1. Creates the Einstein Agent user if missing: profile `Einstein Agent User`, alias `nwagent`, email and time zone copied from the admin, username `nwagent.<admin username>` by default.
2. Assigns the licenses `AgentforceServiceAgentUserPsl` and `GenieDataPlatformStarterPsl`, then the permission sets `AgentforceServiceAgentUser` and `GenieUserEnhancedSecurity` (Data Cloud User).
3. Adds any extra permission sets named in `EXTRA_AGENT_PERMSETS="PermSetApiName1,PermSetApiName2"`.
4. Gives the admin, as the specialist, `ServiceUserPsl` and `EmbeddedServiceMessagingUserPsl`, plus `LiveMessageUserPsl` if a seat is free, then `NW_Live_Support_Agent`.
5. Adds the admin to queue `NW_Live_Support`.
6. Prints the agent username on the last line (`<agent-user-username>` in the reference org). In runbook step 10 that username replaces `__AGENT_USER_USERNAME__` in the `.agent` file.

Options: `DRY_RUN=1` (reads only), `SKIP_ADMIN=1`, `AGENT_USERNAME=...`, `ADMIN_USERNAME=...`, `EXPECTED_ORG_ID=...` (stop if the alias points to another org).

Queue membership isn't part of the Queue metadata. If the queue is redeployed, re-run the script to restore the admin's membership.

### 4.3 Publish the agent

`NW_Escalate_To_Live_Agent` must be active before the agent is published (runbook step 10, `agent.md` sections 5 and 6), because the connection blocks name it:

```
connection messaging:
   escalation_message: "..."
   outbound_route_type: "OmniChannelFlow"
   outbound_route_name: "flow://NW_Escalate_To_Live_Agent"
   adaptive_response_allowed: True

connection customer_web_client:
   (same four properties)
```

Without `--version`, `sf agent activate` shows a version picker; with `--json` it activates the latest version and does not prompt. You can also pass the version, for example `--version 6`, the active version in the reference org.

### 4.4 Inbound flow and messaging channel

The inbound flow refers to the agent by DeveloperName (`<setupReference>Northwind_Service_Agent</setupReference>`, `<setupReferenceType>BotDefinition</setupReferenceType>`). The Metadata API accepts a reference to an agent that doesn't exist (a bad service channel reference, by contrast, is rejected), so a flow deployed before the agent could hold an unresolved agent and send every chat to the fallback queue. Deploy or redeploy it only after 4.3, then deploy the channel (runbook steps 12 and 13). After both deploys, the MessagingChannel query in step 13 shows a `SessionHandlerId` starting with `300` (the flow definition), a `FallbackQueueId` starting with `00G`, and `IsActive` false until 5.2.

Confirm the agent reference resolved:

1. Setup > Process Automation > Flows > NW Route Messaging To Agent > open the active version.
2. Open the Route To Northwind Service Agent element.
3. Route To is the Agentforce agent, the agent field shows Northwind Service Agent, and the fallback queue uses the ID from the `Get_Fallback_Queue` record.
4. If the agent field is empty, pick Northwind Service Agent, Save As New Version and Activate.

## 5. Messaging channel activation

### 5.1 Messaging must be on

`LiveMessage.settings-meta.xml` sets `<enableLiveMessage>true</enableLiveMessage>` and is deployed in runbook step 3. If that deploy is rejected, use Setup:

1. Setup > Quick Find "Messaging Settings" > Messaging Settings.
2. If the Messaging toggle at the top is off, turn it on.

### 5.2 Activate NW_Web_Chat

1. Setup > Messaging Settings > Northwind Web Chat (NW_Web_Chat).
2. In the Omni-Channel Routing section, check: Routing Type Omni-Channel Flow, Flow Definition NW Route Messaging To Agent, Fallback Queue Northwind Live Support. Set any missing value with the pencil icon.
3. Click Activate, accept the terms and conditions, and save.

In the reference org the channel was activated in Setup. The CLI alternative is a direct data update:

```bash
sf data update record -o northwind-dev --sobject MessagingChannel --where "DeveloperName='NW_Web_Chat'" --values "IsActive=true"
```

## 6. Embedded service deployment NW_Portal_Chat

Prerequisites: Digital Experiences is enabled, the Northwind Support site (Build Your Own (LWR), path `support`) exists, and NW_Web_Chat is active.

Web deployments can't be created with the Metadata API, because of a circular dependency between the Network and CustomSite types. Creating one also generates `ESW_<name>_<timestamp>` sites; in the reference org there are two, both named `ESW_NW_Portal_Chat_` followed by a timestamp. Use one of these options.

### Option A: Setup (recommended)

1. Setup > Quick Find "Embedded Service" > Embedded Service Deployments > New Deployment.
2. Select Messaging for In-App and Web (may be labeled Enhanced Chat) > Next.
3. Select Web > Next.
4. Fill in:
   - Embedded Service Deployment Name: `NW Portal Chat`
   - API Name: `NW_Portal_Chat`
   - Domain: `<my-domain>.my.site.com`. If asked to choose between an Experience Cloud site and another website, choose the Experience Cloud site Northwind Support.
   - Messaging Channel: Northwind Web Chat
5. Save. On the deployment settings page, click Publish. Publishing can take up to 10 minutes to take effect.
6. Optional: Test Enhanced Web Chat (or Test Messaging) on the deployment. The test page loads the widget as a guest, which works because the channel uses `authMode` UnAuth.

### Option B: Connect API

The `POST /services/data/v67.0/connect/embeddedmessaging/deployment/setup` call with the channel ID and host domain is in runbook step 14. It changes the org and is not idempotent, so run it once.

Verify:

```bash
sf data query -o northwind-dev --use-tooling-api -q "SELECT Id, DeveloperName, DeploymentType, DeploymentFeature, IsEnabled, ClientVersion FROM EmbeddedServiceConfig WHERE DeveloperName='NW_Portal_Chat'"
sf data query -o northwind-dev -q "SELECT Name, UrlPathPrefix, SiteType FROM Site WHERE Name LIKE 'ESW_NW_Portal_Chat%'"
```

To republish after a later change:

```bash
sf api request rest "/services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<EmbeddedServiceConfig ID>" -X POST -o northwind-dev
```

### 6.1 Put the chat on the portal

Covered in `experience-portal.md`:

- CSP and CORS entries for the site and SCRT domains are in `force-app/main/default/corsWhitelistOrigins/` (`NW_Portal_Site_Origin`, `NW_Messaging_SCRT_Origin`) and `cspTrustedSites/`.
- `scripts/create-portal.sh messaging` places `experience_messaging:embeddedMessaging` in the theme layout footers once `NW_Portal_Chat` exists. It does not publish; run `scripts/create-portal.sh publish` afterward (`experience-portal.md` section 6.4).

If the script can't place the component, use Builder:

1. Setup > Digital Experiences > All Sites > Northwind Support > Builder.
2. Drag Embedded Messaging into the theme layout footer.
3. Set Deployment to `NW_Portal_Chat` and Hide Chat Button on Load to Default.
4. Publish.

Then open `https://<my-domain>.my.site.com/support` in a private window. The chat button appears at the bottom right.

## 7. Specialist workspace

1. Setup > App Manager > Service Console (LightningService) > Edit.
2. Utility Items (Desktop Only) > Add Utility Item > Omni-Channel > Save.
3. Lightning App Builder > the Messaging Session record page used in the Service Console: replace the classic Conversation component with Enhanced Conversation, save, and activate as the org default. Without it an accepted chat opens with no conversation pane.
4. App Launcher > Service Console > Omni-Channel utility > set status Available - Messaging. If the status isn't listed, check that `NW_Live_Support_Agent` is assigned (re-run `scripts/setup-agent-user.sh`) and reload the console.

## 8. End-to-end test

The portal test, including the check that a chat waits in the queue while no specialist is online, is in `docs/TEST_PLAN.md` section 7. After an escalation:

```bash
sf data query -o northwind-dev -q "SELECT Id, Status, Origin, OwnerId, CreatedDate FROM MessagingSession ORDER BY CreatedDate DESC LIMIT 5"
sf data query -o northwind-dev -q "SELECT Id, WorkItemId, UserId, Status, OriginalQueueId, RoutingType, BotId FROM AgentWork ORDER BY CreatedDate DESC LIMIT 5"
```

## 9. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Chat shows "Agents are not available" when the session starts | The queue has no routing configuration. Check `SELECT QueueRoutingConfigId FROM Group WHERE DeveloperName='NW_Live_Support'` and redeploy the queue if it's null. |
| New chats go straight to the queue instead of the agent | The agent reference in `NW_Route_Messaging_To_Agent` didn't resolve, or the agent is inactive. Redeploy the flow after `sf agent activate` and check the Route Work element (4.4). If the fallback queue lookup is the problem, set the queue as a fixed 18-character ID (`stringValue`, `isQueueVariable` false) instead of the Get Records result. |
| Agent says it can't transfer | In a portal chat, check that the connection blocks' `outbound_route_name` matches the active flow `NW_Escalate_To_Live_Agent`. CLI preview and Testing Center have no messaging session and don't show this reply: preview returns an Escalate message with no text, and Testing Center records only "User requested escalation to human." |
| Escalated chat sits in the queue | No specialist is Available - Messaging, or the specialist isn't a queue member. The chat is offered once someone with the presence status is online. |
| Available - Messaging is missing in Omni-Channel | `NW_Live_Support_Agent` isn't assigned, or the Omni-Channel utility isn't in the app. |
| Assigning `NW_Live_Support_Agent` fails with a license error | The admin lacks the Enhanced Chat User license (`EmbeddedServiceMessagingUserPsl`). The script assigns it first; check the seat count. |
| Channel can't be activated | Turn on Messaging (5.1). Check that the inbound flow is active and the fallback queue supports MessagingSession. |
| Widget doesn't show on the portal | The deployment isn't published, the CSP and CORS metadata isn't deployed, or the site wasn't republished after the component was added. |
| Accepted chat opens with no conversation pane | The Messaging Session record page needs the Enhanced Conversation component (section 7, step 3). |
| Guests see the chat button but can't start a conversation | Check the channel first: `embeddedConfig.authMode` must be `UnAuth` (it is in source). Only if the channel is correct and guests still can't chat, look at the `NW_Portal_Chat` flag `AreGuestUsersAllowed`; it is not normally needed for Enhanced Chat guests. |
| Deploying MessagingChannel fails with "Property 'endUserIdleTimeOut' not valid in version 66.0" | That property needs API 67 or later and is left out of the file. Keep it out while `sourceApiVersion` is 66.0. |
