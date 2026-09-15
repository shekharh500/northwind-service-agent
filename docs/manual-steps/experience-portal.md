# Experience Cloud Portal

Customers reach the agent through Northwind Support, a Build Your Own (LWR) site at `/support` with the Embedded Messaging chat in its theme footer. Only a small part of the site is deployable metadata: the Digital Experiences settings, two Trusted URLs and two CORS origins under `force-app/main/default`. The site itself is created and changed by `scripts/create-portal.sh`, and the home page is applied from `portal/home/home.html` by `scripts/update-portal-home.py`. Runbook steps 3, 7, 14 and 15 put these together in order; the sections below explain each part and give the Experience Builder alternatives.

## 1. Components

| Item | Value | Purpose |
| --- | --- | --- |
| `CommunitiesSettings.enableNetworksEnabled` | `true` | Turns on Digital Experiences |
| `ExperienceBundleSettings.enableExperienceBundleMetadata` | `true` | Optional. Only Aura sites need it (for example, to retrieve an auto-generated `ESW_*` site as `ExperienceBundle`). LWR sites use `DigitalExperienceBundle` |
| CSP Trusted URL `NW_Messaging_SCRT` | `https://*.salesforce-scrt.com`, context All, all 6 directives | SCRT2 is the Enhanced Chat runtime host |
| CSP Trusted URL `NW_Portal_Site_Domain` | `https://<my-domain>.my.site.com`, context All, all 6 directives | The portal and the `ESW_NW_Portal_Chat_*` chat site share this domain |
| CORS origin `NW_Portal_Site_Origin` | `https://<my-domain>.my.site.com` | Experience Cloud site domain |
| CORS origin `NW_Messaging_SCRT_Origin` | `https://<my-domain>.my.salesforce-scrt.com` | The org's SCRT2 origin |
| `scripts/create-portal.sh` | Steps `preflight`, `create`, `retrieve`, `activate`, `messaging`, `publish`, `status`, `all`. `DRY_RUN=1` prints each command that would change the org instead of running it | Creates, activates, adds the chat component to and publishes the site |

In source, the site and SCRT hosts in the CSP and CORS files are written with the placeholder `__MY_DOMAIN__`. Runbook step 7 replaces it with the org's My Domain name before the deploy.

Check-only validation of the settings, CSP and CORS components:

```bash
sf project deploy validate -o northwind-dev --test-level RunLocalTests --source-dir force-app/main/default/cspTrustedSites --source-dir force-app/main/default/corsWhitelistOrigins --source-dir force-app/main/default/settings/Communities.settings-meta.xml --source-dir force-app/main/default/settings/ExperienceBundle.settings-meta.xml
```

Notes:

- `--test-level NoTestRun` is not accepted by `deploy validate` in CLI 2.106.6, which only allows `RunAllTestsInOrg`, `RunLocalTests` or `RunSpecifiedTests`.
- CSP descriptions are limited to 255 characters.
- Full `https://` URLs in `endpointUrl` validate.

## 2. Reference org

- Digital Experiences is enabled. Enhanced domains were already provisioned (`Domain` rows `<my-domain>.my.site.com`, CommunityAlt, and `<my-domain>.my.salesforce-sites.com`, SitesAlt), so there was no domain name to choose.
- The site was created on September 14, 2026 (job `08PXXXXXXXXXXXXXXX`, `SiteTaskCreate`). Network `0DBXXXXXXXXXXXXXXX`, name Northwind Support, now status Live.
- Site rows: `Northwind_Support1` (`ChatterNetworkPicasso`, prefix `support`) and `Northwind_Support` (`ChatterNetwork`, prefix `supportvforcesite`). `Network.UrlPathPrefix` is `supportvforcesite`, so the script looks the Network up by name, not by prefix.
- The `DigitalExperienceConfig` has `urlPathPrefix` `support` and space `site/Northwind_Support1`. The `sfdc_cms__site` `authenticationType` is `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED`.
- Theme layouts: `scopedHeaderAndFooter` (footer > `community_layout:section` > `footerSection`) and `snaThemeLayout` (bare footer region).
- The embedded service deployment `NW_Portal_Chat` (Web, WebV2) generated the sites `ESW_NW_Portal_Chat_<timestamp>` and `ESW_NW_Portal_Chat_<timestamp>1`.
- `sf community list template` returns Build Your Own (LWR) along with Build Your Own, Help Center, Lightning Out (LWR), Customer Account Portal, Customer Service, Aloha, and Salesforce Tabs + Visualforce.
- Agent user permission sets and licenses available: `AgentforceServiceAgentUser`, `GenieUserEnhancedSecurity` ("Data Cloud User"), group `AgentforceServiceAgentUserPsg`, licenses `AgentforceServiceAgentUserPsl` and `GenieDataPlatformStarterPsl`.

## 3. Order of operations

1. Data Cloud provisioning finishes.
2. Enable Digital Experiences (section 4). This must come before the web deployment `NW_Portal_Chat` is created, because creating it generates `ESW_<name>_<timestamp>` Experience sites.
3. Deploy the CSP and CORS metadata (section 7.4). They don't depend on anything else.
4. Run `scripts/create-portal.sh preflight create retrieve activate` (section 5). `create` skips if the site exists.
5. Chat channel work (`escalation-and-chat.md`):
   - `NW_Web_Chat` is active and routed through `NW_Route_Messaging_To_Agent`, with `embeddedConfig.authMode` `UnAuth`.
   - `NW_Portal_Chat` (Web, `WebV2`) is published with host domain `<my-domain>.my.site.com`.
   - `AreGuestUsersAllowed` on the deployment is not a prerequisite. Guest access to Enhanced Chat comes from the channel's `UnAuth` mode. Only change the flag as a troubleshooting step (`escalation-and-chat.md` section 9).
6. Add the Embedded Messaging component (section 6) with `scripts/create-portal.sh messaging` or in Experience Builder.
7. Run `scripts/create-portal.sh publish`, then check as a guest (section 9).

## 4. Enable Digital Experiences

Already enabled in the reference org. Use this on a new org, or if the check in 4.3 fails.

### 4.1 Metadata

Deploy `Communities.settings-meta.xml`, and optionally `ExperienceBundle.settings-meta.xml` after it, as in runbook step 3.

`enableNetworksEnabled` is available from API 47.0. Where enhanced domains already exist, the domain is fixed and nothing else has to be chosen.

Enabling this in Setup returned an internal server error while Data Cloud provisioning was still running, and a check-only validation doesn't exercise that part of the platform. Wait until provisioning shows complete before deploying. If the deploy still errors, use the click path.

This is a one-way change: Setup has no option to turn Digital Experiences off again.

### 4.2 Click path

1. Setup > Quick Find "Digital Experiences" > Settings.
2. Select Enable Digital Experiences. The domain shown is the enhanced domain `<my-domain>.my.site.com` and can't be edited.
3. Save and confirm.
4. Optional: select Enable ExperienceBundle Metadata API on the same page and save. Only Aura sites need it.

### 4.3 Verify

```bash
sf data query -o northwind-dev -q "SELECT Id FROM Network LIMIT 1"   # must not error
scripts/create-portal.sh preflight                                             # org guard, Digital Experiences, template
```

## 5. Create, retrieve, activate and publish the site

### 5.1 Script

Runbook step 15 gives the order: `status` and a `DRY_RUN=1 ... all` preview first, then `preflight create retrieve activate`, `messaging` once `NW_Portal_Chat` is published (section 6), and `publish`.

With `DRY_RUN=1` the script prints `sf community create`, `sf project deploy start` and `sf community publish` instead of running them. It still runs read-only queries, retrieves into `$WORK_DIR`, and check-only `sf project deploy validate` (`RunLocalTests`, rolled back).

A step whose prerequisite is missing (Digital Experiences or the site) logs it and skips. Without `DRY_RUN=1`, `create`, `activate`, `messaging` and `publish` change the org, so run `status` first. The org alias, org ID, site name, prefix and domain can be overridden with environment variables listed in the script header. `SITE_DOMAIN` defaults to the placeholder `https://__MY_DOMAIN__.my.site.com`, and `messaging`, `publish` and `all` stop until it is set to the org's site domain (`config/org-values.example.env`).

What each step does:

- Org guard. Every step first checks that `sf org display` can read the alias in `ORG_ALIAS`. If `EXPECTED_ORG_ID` is set, the step also stops unless the org has that ID. With `EXPECTED_ORG_ID` empty the ID check is skipped and the script logs a warning.
- `create` runs:

  ```bash
  sf community create --name "Northwind Support" --template-name "Build Your Own (LWR)" \
    --url-path-prefix support templateParams.AuthenticationType=AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED --json
  ```

  It skips when `SELECT Id FROM Network WHERE Name='Northwind Support'` returns a row. Otherwise it polls the returned job with `SELECT Id, Status, Error FROM BackgroundOperation WHERE Id='<jobId>'` until `Complete` (possible values: New, Scheduled, Canceled, Merged, Waiting, Running, Error, Complete), then waits for the `Network` row.
- Authentication type. A Build Your Own (LWR) site needs `templateParams.AuthenticationType` of `AUTHENTICATED` or `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED`. `UNAUTHENTICATED` is not supported for LWR sites created after Winter '23. `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED` is the same as Public can access the site in Experience Builder > Settings > General.
- `retrieve` pulls `DigitalExperienceConfig`, `DigitalExperienceBundle`, `Network:Northwind Support` and `CustomSite` in metadata format into `$WORK_DIR/retrieve` (default `$TMPDIR/nw-portal-work`). It finds the bundle name from the `DigitalExperienceConfig` whose `site/urlPathPrefix` is `support` (`site/Northwind_Support1` in the reference org), falling back to that name with a warning. The metadata root goes to `$WORK_DIR/retrieve.root` and the bundle name to `$WORK_DIR/bundle.name`. Nothing is written under `force-app/`.
- `activate` retrieves `Network:Northwind Support`, sets `<status>` to `Live`, validates and then deploys with `--metadata-dir`. New sites start as `UnderConstruction` and can't be reached until they are Live. Activating an Experience Builder site sends a welcome email to its members; on a new site the only member profile is the admin's. If the Network deploy is rejected, use Workspaces > Administration > Settings > Activate.
- `publish` runs `sf community publish --name "Northwind Support" --json`. The CLI finds the site by exact name. The step polls the `BackgroundOperation`, logs the Network status, and requests `https://<my-domain>.my.site.com/support/` expecting HTTP 200, retrying up to 4 times 60 seconds apart.
- JSON output is read from stdout only. The CLI prints notices such as `Warning: @salesforce/cli update available` on stderr, and merging them with `2>&1` breaks the JSON.

To keep the site in source control, convert the retrieved bundle:

```bash
sf project convert mdapi --root-dir "$(cat "${TMPDIR:-/tmp}/nw-portal-work/retrieve.root")" \
  --output-dir force-app/main/default
```

The retrieve uses wildcards, so the root holds every site in the org, including `digitalExperiences/enablement/sfdcEnablement_EnablementWorkspace` and the `ESW_NW_Portal_Chat_*` sites. Commit only the Northwind Support components (`site/Northwind_Support1`, `digitalExperienceConfigs/Northwind_Support1`, `networks/Northwind Support`, `sites/Northwind_Support`) and never deploy the `ESW_*` sites; web embedded service sites can't be created through the Metadata API.

### 5.2 Click path

1. Setup > Digital Experiences > All Sites > New.
2. Choose Build Your Own (LWR) > Get Started.
3. Name `Northwind Support`, URL `support` > Create.
4. Builder > Settings > General: select Public can access the site.
5. Workspaces > Administration > Settings: Activate.
6. Builder: Publish.

### 5.3 Home page and site title

The home page text lives in `portal/home/home.html`. `scripts/update-portal-home.py <bundle-site-dir>` writes it into the rich text component of `sfdc_cms__view/home` only, sets the page title and description on the SEO component, and leaves every other component untouched. Run it on a retrieve of just the home view and deploy that single component. Deploying the whole bundle would also replace the theme layouts, routes and other views with the retrieved copies, undoing Builder changes such as the chat component.

```bash
rm -rf "$TMPDIR/nw-home-single"
sf project retrieve start -o northwind-dev \
  --metadata "DigitalExperience:site/Northwind_Support1.sfdc_cms__view/home" \
  --target-metadata-dir "$TMPDIR/nw-home-single" --unzip
python3 scripts/update-portal-home.py \
  "$TMPDIR/nw-home-single/unpackaged/unpackaged/digitalExperiences/site/Northwind_Support1"
sf project deploy validate -o northwind-dev --test-level RunLocalTests \
  --metadata-dir "$TMPDIR/nw-home-single/unpackaged/unpackaged"
sf project deploy start -o northwind-dev --metadata-dir "$TMPDIR/nw-home-single/unpackaged/unpackaged"
scripts/create-portal.sh publish
```

The live page changes only after the publish. To confirm what the org stored, retrieve the home view again into an empty folder and run the script on it with `--check`, which exits 1 when the stored page differs from `home.html`.

The site `<title>` and meta description are set in `sfdc_cms__appPage/mainAppPage`; `portal/site/mainAppPage.content.json` holds the deployed copy.

In the reference org the current `home.html` was deployed this way and the site was published on September 15, 2026. The page has:

- A navy header band with the H1 "Northwind Home Support" and a one-line subtitle.
- A short introduction that points to the Ask Me Anything chat button and explains how to reach a specialist.
- Help topics: Warranty, Returns and refunds, Aura Smart Thermostat T200 and CarePlus service plans, each with a few example questions.
- Contact us: live support hours (Monday to Friday, 8 a.m. to 8 p.m.; Saturday, 9 a.m. to 5 p.m.) and a table of first-response times by plan.
- A Safety issues notice (disconnect power, then open the chat; Priority 1 handling).
- A footer with the copyright line and a note that Northwind Home is a fictitious company.

Hours, prices and response times come from NWH-POL-001, NWH-POL-002, NWH-MAN-T200 and NWH-SVC-004.

## 6. Add Embedded Messaging to the site

### 6.1 Prerequisites

- `NW_Portal_Chat` exists as a Web deployment on client version `WebV2` and is published. An unpublished or v1 deployment never serves the widget.
- `NW_Web_Chat` is active and routes to the agent.

```bash
sf data query -o northwind-dev --use-tooling-api \
  -q "SELECT Id, DeveloperName, AreGuestUsersAllowed FROM EmbeddedServiceConfig WHERE DeveloperName='NW_Portal_Chat'"
sf data query -o northwind-dev \
  -q "SELECT Name, UrlPathPrefix, SiteType, Status FROM Site WHERE Name LIKE 'ESW_NW_Portal_Chat%'"
```

### 6.2 Component values

| Attribute | Value |
| --- | --- |
| `deploymentName` | `NW_Portal_Chat` |
| `scrtUrl` | `https://<my-domain>.my.salesforce-scrt.com`: the instance URL with `.my.salesforce.com` changed to `.my.salesforce-scrt.com`. Confirm on the deployment's code snippet page |
| `siteEndpoint` | `https://<my-domain>.my.site.com/<UrlPathPrefix>`, using the `ESW_NW_Portal_Chat_*` Site row whose prefix does not end in `vforcesite` (`ESWNWPortalChat<timestamp>` in the reference org) |
| `isExpSiteAuthMode` | `false`: guests allowed, matching the channel's `UnAuth` mode |
| `hideChatButtonOnLoad` | `Default` |
| `clientVersion` | `WebV2` |

### 6.3 Experience Builder

1. Setup > Digital Experiences > All Sites > Builder next to Northwind Support.
2. In the Components panel, search for Embedded Messaging.
3. Drag it into the theme footer so it shows on every page as a floating launcher. Dropping it on the Home page content region also works, but then it only shows on Home.
4. In the property editor:
   - Deployment: NW_Portal_Chat. If it isn't listed, the deployment isn't published yet.
   - Hide Chat Button on Load: Default.
   - Leave auth mode unchecked for this public site.
   - Check the endpoint fields against 6.2.
5. Publish and confirm.
6. After 30 to 60 seconds, open `https://<my-domain>.my.site.com/support/` in a private window. The launcher appears at the bottom right.

### 6.4 Metadata (script)

`scripts/create-portal.sh messaging` does the same through the site bundle, and can be re-run:

1. Resolves the six values in 6.2. `SCRT_URL` and `SITE_ENDPOINT` override them. For `siteEndpoint` it uses the newest `ESW_NW_Portal_Chat_*` Site row with `SiteType` `ChatterNetworkPicasso` and a prefix that doesn't end in `vforcesite`.
2. Runs `retrieve` to find the bundle name, then retrieves only `DigitalExperienceBundle:site/<bundle>`.
3. Patches every `sfdc_cms__themeLayout/*/content.json`. In `scopedHeaderAndFooter` the node goes into `footerSection`; in `snaThemeLayout` into the bare footer.
4. If `sfdc_cms__site/*/content.json` has a different `contentBody.authenticationType` than `AUTH_TYPE`, sets it (default `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED`). This matters for a site created by click path without Public can access the site.
5. Validates, then deploys with `--metadata-dir`.

`messaging` does not publish. Run `publish` after it.

Placement:

- In `.contentBody.component.children[]`, find the region with `"type": "region"` and `"name": "footer"`. Inside its `community_layout:section` child, add the node to the first inner region (for example `footerSection`). If the footer has no section, add it to the footer's own `children[]`.
- Node shape for LWR:

```json
{
  "id": "<fresh uuid>",
  "type": "component",
  "definition": "experience_messaging:embeddedMessaging",
  "attributes": {
    "deploymentName": "NW_Portal_Chat",
    "scrtUrl": "https://<my-domain>.my.salesforce-scrt.com",
    "siteEndpoint": "https://<my-domain>.my.site.com/<ESW UrlPathPrefix>",
    "isExpSiteAuthMode": false,
    "hideChatButtonOnLoad": "Default",
    "clientVersion": "WebV2"
  }
}
```

Rules:

- LWR uses `definition` and `attributes`. Aura uses `componentName` and `componentAttributes`, and using the wrong keys silently drops the component.
- On a re-run, update the existing node in place and keep its `id`. Never add a second node.
- Patch the theme layout footers, not `sfdc_cms__view/home/content.json`, which only affects Home.
- Changes reach the live site only after publishing.
- If the deploy fails because a template route such as `too-many-requests` is missing, re-retrieving won't add it. Create the missing `sfdc_cms__route` and `sfdc_cms__view` pair, or use the Builder path in 6.3.

Check the placement after a round trip:

```bash
python3 - "$(cat "${TMPDIR:-/tmp}/nw-portal-work/retrieve.root")" <<'PY'
import glob, json, sys
for p in glob.glob(sys.argv[1] + "/digitalExperiences/site/*/sfdc_cms__themeLayout/*/content.json"):
    s = json.dumps(json.load(open(p)))
    print(p, s.count('"experience_messaging:embeddedMessaging"'))
PY
```

Each theme layout should report 1.

## 7. Guest and member access

### 7.1 Site access

- `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED` lets guests and logged-in members use the site. Builder > Settings > General shows Public can access the site.
- For a members-only site, set `AUTH_TYPE=AUTHENTICATED`. The chat would then need `Auth` mode with JWT user verification, which this build doesn't include.

### 7.2 Chat access

- Channel `NW_Web_Chat` has `embeddedConfig.authMode` `UnAuth`. Guests chat anonymously, and it still works for logged-in visitors. `Auth` mode would break anonymous visitors and the Setup Test Enhanced Web Chat page.
- On `NW_Portal_Chat`, leave `AreGuestUsersAllowed` at the value Setup or the Connect API created. It is only worth changing if guests see the button but can't start a chat while the channel is already `UnAuth` (`escalation-and-chat.md` section 9).
- The component has `isExpSiteAuthMode` `false`.

### 7.3 Guest user profile

Salesforce creates the guest profile Northwind Support Profile with the site.

- Don't grant it object, Apex, Data Cloud, Einstein or Agentforce permissions. Embedded Messaging needs none: the messaging platform creates the session, the Omni-Channel flow routes it, and the agent user handles it.
- Embedded Messaging doesn't need a guest permission set, `Network.OptionsGuestChatterEnabled`, `OptionsGuestMemberVisibility`, relaxed CSP or `clickjackProtectionLevel=AllowAllFraming`. Add one only if a specific error points to it.
- Optional, for members: add the Customer Community or Customer Community Login profiles in Workspaces > Administration > Members. That needs portal users with contacts, which this build doesn't include.

### 7.4 CSP Trusted URLs and CORS

Runbook step 7 deploys both folders and queries the result (2 `CspTrustedSite` rows named `NW_%`, 2 `CorsWhitelistEntry` rows).

Setup equivalents: Quick Find "CORS" > New, enter the origin URL pattern; Quick Find "Trusted URLs" > New Trusted URL, enter the URL, CSP context and directives.

What the entries are for:

- The site domain goes on the CORS allowlist (Setup > CORS), the usual setup for Enhanced Chat on an Experience Cloud site.
- The chat component talks to the SCRT2 host in `scrtUrl`, so SCRT2 and the portal URL are allowed for both CORS and Trusted URLs with all six directives.
- The portal (`/support`) and the ESW chat site share the `my.site.com` origin, so `'self'` already covers most embedded traffic and same-origin framing is allowed by the default clickjack setting.
- The entries are broad. Narrowing them to the Communities context, or turning off font, style or media directives, is optional hardening once the chat works.

If the launcher is blank or missing:

1. In the browser console on the public page, look for `Refused to connect`, `Refused to frame` or `Content Security Policy` messages, and add the reported host and directive as a Trusted URL.
2. For `Refused to frame ... frame-ancestors`, check the clickjack protection setting on the `ESW_NW_Portal_Chat_*` site.
3. Check that `siteEndpoint` uses the non-`vforcesite` ESW prefix and that `NW_Portal_Chat` is published.
4. Publish the portal again.

The launcher is rendered by JavaScript in the browser, so it doesn't appear in the HTML returned by `curl`.

## 8. Data Cloud access when the visitor is a guest

- The guest user never touches Data Cloud. An Enhanced Chat session from the portal is routed by `NW_Route_Messaging_To_Agent` to `Northwind_Service_Agent`, which runs as its Einstein Agent user (`<agent-user-username>`). The actions, the `NW_Doc_*` prompt templates, the retriever `File_Northwind_Home_Docs_1Cx_<suffix>` and the search index all run as that user.
- Don't give the guest profile any Data Cloud or Einstein access.
- The agent user needs:
  - `AgentforceServiceAgentUser`, which requires the Agentforce Service Agent User license.
  - `GenieUserEnhancedSecurity` ("Data Cloud User") with license `GenieDataPlatformStarterPsl`.
  - Access to the `default` data space, if the org requires it. This can only be set in Setup: Setup > Permission Sets > Data Cloud User > Data Space Access, add the default data space, save. A grounded query that reports success but returns nothing usually means this access is missing.
- Anything in the data library can be surfaced to anonymous visitors, so index only public content. The four fictitious Northwind Home PDFs are public by design.
- Citations: the templates have citations enabled and the files come from an SFDRIVE library. Links to Salesforce-hosted files may not open for a guest, who has no file access; the answers also name the source document in the text, which works for everyone. During guest testing, check whether citation links render and open. If they show as broken, rely on the in-text source names or turn off citation links for the channel.
- Logged-in members get the same agent user and the same answers. Nothing in this build personalizes retrieval.

## 9. Guest checklist

In a private browser window:

1. `https://<my-domain>.my.site.com/support/` returns HTTP 200 and loads without a login prompt.
2. The chat launcher appears at the bottom right on Home and at least one other page, which confirms the footer placement.
3. The agent's welcome message appears, which confirms the channel, the inbound flow and the agent are active.
4. Answers come from the PDFs and name the source:
   - "How long is the warranty on the Aura T200 thermostat?" From `01-warranty-policy`: 24 months from purchase, extended to 36 months if the device is registered within 30 days.
   - "Summarize the CarePlus service plans". From `04-careplus-service-plans-sla`: Basic and Premium tiers, bought with the device or within 60 days. Basic has live chat within 5 minutes; Premium has priority chat within 2 minutes and a phone callback within 1 hour.
5. "I want to talk to a human": with a specialist on Available - Messaging, the session transfers to queue `NW_Live_Support` through `NW_Escalate_To_Live_Agent`.
6. The browser console shows no CSP or CORS errors.

## 10. Rollback

- Remove the chat: delete the component in Builder, or re-run the patch without it, then publish.
- Take the site offline: Workspaces > Administration > Settings > Deactivate.
- Remove the CSP and CORS entries: delete them in Setup (Trusted URLs, CORS).
- Digital Experiences stays enabled.
