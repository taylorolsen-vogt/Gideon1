# Gideon — capabilities and roadmap

Last reviewed: 2026-09-05

## How we use this document

This is our single working list of what Gideon does, what needs work, and ideas worth keeping. **An idea recorded here is not an instruction to implement it.** Choose one small task together before starting development; keep unrelated ideas in the backlog.

- Distinguish **implemented**, **user-verified**, **setup only**, and **planned**.
- A saved credential or a “Connected” label does not prove a tool exists or an action is permitted.
- Update this document as capabilities are tested or decisions change, rather than creating a new plan for every conversation.
- Never store passwords, API keys, tokens, or private message contents here.

## Current focus

**Now: organize the plan only.** No activity UI changes, new integrations, or permission changes are authorized by creating this document.

**Proposed next milestone: enable Gideon to make a small, reviewable change to Aqua without granting access to other private repositories.** This requires both appropriately scoped GitHub authorization and working write tools; permission changes alone are insufficient.

## What works, and what does not yet

| Area | Current state | Evidence / limitation |
| --- | --- | --- |
| Model-driven tool use | Implemented | Native multi-step tool loops for Claude, Gemini, and OpenAI-compatible providers. Capability varies by model; not every provider/model is live-verified. |
| Gmail search/read | Implemented | Search, metadata, and plain-text bodies. HTML and attachments are not read by the native tools. |
| Gmail sending | Implemented; user-verified | Local preparation → review sender, recipients, subject, body → native confirmation → Gmail send. User reports receiving the test email. This does not establish delivery to every recipient or validate every failure case. |
| GitHub inspection | Implemented; Aqua read access user-reported | Repository listing, directory/file reads, issues, and workflow results. The user's token's exact granted permissions have not been independently audited. |
| GitHub code changes / pull requests | Not implemented in native agent tools | No code-write, commit, branch, or pull-request creation tools. A legacy explicit slash command can create an issue; that is not code-writing capability. |
| Build and test execution | Planned | No connected worker where Gideon can edit an isolated checkout, run a build, test the game, and return artifacts. |
| Project context | Implemented | Models can list projects and read saved briefs and linked activity. This is not an autonomous project delivery system. |
| Activity | Partial; improvements requested | Records and a feed exist. Natural-language event summaries and richer action details are backlog items, not completed by this planning pass. |
| Connections | Partially set up, not finished | Catalog and credential/OAuth setup exist. Most listed services have no executable agent tools. See inventory below. |
| Cross-device credential availability | Needs verification | During simulator testing, provider records restored but Claude/Gemini showed “Needs Key.” Do not assume every device has usable credentials merely because records appear. |

Previous validation: simulator build and mocked provider/tool tests passed, including email approval and send outcomes. Mocked tests are not live service verification. The user's report of receiving the email is the current real-world email milestone.

## Aqua: safe path to write access

**Goal:** let Gideon work on Aqua while keeping other private repositories out of reach.

Proposed approach — not configured yet:

1. Confirm Aqua's exact owner/repository and the existing connection's actual permissions.
2. Use a **fine-grained GitHub token**, with **Only select repositories → Aqua**, an expiration, and no unnecessary account/organization permissions. Do not use a broad classic `repo` token.
3. Grant only the capabilities the chosen implementation needs:
   - Contents: read/write for code changes.
   - Pull requests: read/write if Gideon will open reviewable PRs.
   - Issues: write only if issue creation is needed.
   - Actions: read for inspecting runs; avoid workflow-file write and administration permissions initially.
4. Add an Aqua repository allowlist in the executor as a second check. Keep tokens outside model prompts and build output.
5. Work on a dedicated branch, show the diff, and require review before merging. Protect the default branch; do not provide bypass, force-push, deletion, or admin capabilities.
6. Test that attempts to write another repository are rejected, not merely discouraged by the model prompt.

Longer-term option: a GitHub App installed only on selected repositories, using short-lived installation tokens.

**Important:** scoped credentials reduce exposure; they do not make arbitrary generated code safe. Builds need an isolated worker with restricted secrets, network access, and execution limits. Gideon's current native GitHub tools remain read-only regardless of token permissions.

## Connections inventory

The existing connection catalog is the earlier list of intended integrations. It describes ambitions as well as setup options; it is not a list of finished adapters.

| Connection | Setup in app | Executable capability today | Remaining work |
| --- | --- | --- | --- |
| Gmail | Google OAuth and manual credential path | Search/read; prepare and confirm a send; legacy draft command | Live account/scope checks, clearer state, richer send history |
| GitHub | Personal access token setup | Read repositories/files/issues/run results; legacy create-issue command | Aqua-only write flow, permissions verification, reviewed changes |
| Google Calendar | OAuth scopes/setup | No native agent adapter | Define limited use case, implement and verify adapter |
| Google Drive | OAuth scopes/setup | No native agent adapter | Scope files appropriately; implement and verify adapter |
| YouTube | OAuth scopes/setup | No native agent adapter | Decide whether needed before implementing |
| Jira | Token + workspace URL setup entry | No Jira agent adapter | Complete authentication inputs/verification and project-scoped issue tools |
| GitLab, Linear | Credential setup entries | No native agent adapters | Prioritize only when an actual workflow needs them |
| Slack, Discord | Credential setup entries | No native agent adapters | Narrow channel permissions and approved write actions |
| Notion, Airtable, Dropbox | Credential setup entries | No native agent adapters | Resource-scoped access and tested tools |
| Figma, Canva | Credential setup entries | No native agent adapters | Decide design workflow and implement a specific adapter |
| CAD | Future idea | None | Choose CAD application, plugin/API, file formats, and safety boundaries |

**Can we connect Jira?** Its setup entry exists, but saving a token is not a working Jira integration. Gideon cannot yet read or update Jira tickets through native tools.

Before calling an integration finished, verify: sign-in/credential storage, actual account identity, granted scopes/resources, a real read, confirmation for writes, actual action result, expiry/reconnect behavior, revocation, and an understandable activity record. Show “setup only” when the adapter does not exist.

## Backlog — recorded, not automatic assignments

### Activity cards

- Use natural-language titles: “Read Aqua's files,” “Email awaiting approval,” or “Gmail accepted your email,” rather than raw tool names.
- Make cards tappable to open action details.
- For an email: preparation/approval/send timestamps with timezone, sender, recipients, subject, message content or a secure reference, outcome, and provider message ID when available.
- Clearly distinguish prepared, cancelled, sending, accepted, rejected, and unknown. “Accepted by Gmail” does not mean recipient delivery was verified.
- Store structured action details rather than reconstructing them from assistant prose. Preserve privacy: no credentials in records or logs; decide retention and cloud-sync behavior for email content.

### Connections clarity and reliability

- Distinguish setup available, credentials saved, verified read, permitted write, expired, and unsupported.
- Check what is genuinely available on each device, including cloud credential sync/reconnect.
- Prioritize Gmail and GitHub before expanding to Jira or additional services.
- Revisit Gemini failures using actual error evidence rather than treating every failure as a routing bug.

### Aqua execution

- Implement narrowly scoped, reviewable repository writes.
- Connect an isolated worker for editing, building, and testing.
- Return diffs, build artifacts, test output, and failure details to Gideon.
- Define cancellation, budgets, approvals, and recovery before unattended work.

### Later ideas

- CAD plugin: retain the idea; application and use case are undecided.
- Other catalog integrations: retain the inventory; choose one when justified by a concrete task.

## Benchmarks

**Gideon's success is measured by completed, verifiable work—not confident replies.** Aqua's success means a functional, enjoyable game, not financial performance.

| Milestone | Acceptance evidence | State |
| --- | --- | --- |
| Send a real email | Recipient confirms receipt | User reports success |
| Inspect Aqua | Real repository data returned | User reports Gideon verified read access; permission scope still to audit |
| Make a safe Aqua change | Aqua-only branch/diff or PR; unrelated repository write denied | Planned |
| Launch Aqua | Runnable game build | Planned |
| Control an aquatic creature | Play as a shrimp, betta, or another chosen creature | Planned |
| Explore/interact | Navigate the environment and perform a meaningful interaction | Planned |
| Fix a reproducible bug | Failing reproduction → change → passing verification | Planned |
| Deliver tested work | Build/test evidence and reviewable artifacts | Planned |

## Open decisions for the next session

- What is Aqua's exact repository, and which isolated write operation should be the first benchmark?
- Start with a fine-grained token or a repository-scoped GitHub App?
- Where should Aqua builds/tests execute, and what platform/engine does Aqua use?
- After the Aqua access milestone, prioritize activity details or connection-state clarity?

These are planning questions, not blockers to maintaining this document or permission to implement the entire backlog.

## Implementation references

- Native tools and Gmail send boundary: [Gideon1/Models/GideonAgentTools.swift](Gideon1/Models/GideonAgentTools.swift)
- Harness and legacy slash commands: [Gideon1/Models/GideonAgentHarness.swift](Gideon1/Models/GideonAgentHarness.swift)
- Provider tool loop: [Gideon1/Models/RemoteGideonRuntime.swift](Gideon1/Models/RemoteGideonRuntime.swift)
- Connection catalog/setup: [Gideon1/Views/HealthView.swift](Gideon1/Views/HealthView.swift)
- Connection verification: [Gideon1/Models/ProviderConnectionStore.swift](Gideon1/Models/ProviderConnectionStore.swift)
- Email approval UI: [Gideon1/Views/MessagesView.swift](Gideon1/Views/MessagesView.swift)
- Activity UI and records: [Gideon1/Views/ActivityView.swift](Gideon1/Views/ActivityView.swift), [Gideon1/Models/ChatSessionStore.swift](Gideon1/Models/ChatSessionStore.swift)
- Mocked regression tests: [Tests/GideonAgentToolsTests.swift](Tests/GideonAgentToolsTests.swift), [Tests/RemoteGideonRuntimeTests.swift](Tests/RemoteGideonRuntimeTests.swift)