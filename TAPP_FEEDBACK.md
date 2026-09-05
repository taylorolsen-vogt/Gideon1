# Tapp iOS Testing Feedback

This report summarizes issues observed while using Tapp to build, launch, authenticate, navigate, and validate the Gideon iOS app on macOS with Xcode simulators.

## Environment

- macOS
- SwiftUI iOS 17 app
- Xcode project: `Gideon1.xcodeproj`
- Scheme: `Gideon1`
- Tested primarily with an iPhone 17 Pro simulator
- Tapp used through the VS Code/Copilot tool integration

## Confirmed Bugs

### 1. Referenced simulator boot tool was unavailable

**Observed:** Tapp instructed the agent to call `tapp_boot_simulator`, but that tool was not exposed in the session, including after tool discovery.

**Expected:** Either expose the recommended tool or recommend an operation that is actually available.

**Workaround:** Boot the simulator using `xcrun simctl boot` and wait with `xcrun simctl bootstatus -b`.

**Priority:** High

### 2. Xcode container auto-detection selected the wrong container

**Observed:** Given the repository directory, Tapp selected `Gideon1.xcworkspace` and failed to detect a scheme. The working container was `Gideon1.xcodeproj` with scheme `Gideon1`.

**Expected:** Detect the buildable project and shared scheme, or return target choices when multiple containers exist.

**Workaround:** Pass the `.xcodeproj` path or a compiled `.app` explicitly.

**Priority:** High

### 3. Build failures omitted diagnostics

**Observed:** `tapp_build_ios_app` returned only `Build failed (scheme Gideon1)` without compiler output, the failing command, or a log path. The project built successfully with `xcodebuild`.

**Expected:** Return the underlying build command, exit code, relevant diagnostic lines, and full log path.

**Workaround:** Build separately with `xcodebuild`, then pass the resulting `.app` to Tapp.

**Priority:** High

### 4. Simulator boot readiness race

**Observed:** After `simctl boot` completed without an error, Tapp still reported that no simulator was booted.

**Expected:** Wait for CoreSimulator to reach a terminal boot state before declaring the simulator unavailable.

**Workaround:** Run `xcrun simctl bootstatus <UDID> -b` before opening the app with Tapp.

**Priority:** Medium

### 5. Opening a new Tapp session restarted the app

**Observed:** Reattaching with `tapp_open_ios_app` changed the app process ID. This prevented same-process background/foreground lifecycle validation.

**Expected:** Provide an attach mode that opens or inspects an already-running app without terminating it.

**Impact:** Tests for state restoration, scene phase behavior, in-memory state, and normal foreground resume can produce invalid conclusions.

**Priority:** High

### 6. Backgrounded-app inspection returned stale accessibility state

**Observed:** After sending the simulator to the Home screen, `tapp_read_ios_screen` timed out but continued to report the previous Gideon screen and controls. A screenshot correctly showed SpringBoard.

**Expected:** Identify that the target app is backgrounded and avoid returning its previous accessibility tree as current state.

**Priority:** High

### 7. Recommended tool names did not match exposed tools

**Observed:** `tapp_open_ios_app` instructed the agent to use `tapp_session_act`, but that tool was not exposed. Only specialized operations such as `tapp_ios_tap` and `tapp_ios_type` were available.

**Expected:** Documentation and tool responses should reference only operations exposed in the current integration.

**Priority:** High

### 8. Text-field matching was inconsistent

**Observed:** Typing into `Message Gideon...` returned `not_found`. Tapping `Message Gideon` and then typing into the focused field succeeded. The rendered placeholder used a typographic ellipsis.

**Expected:** Normalize three periods and the ellipsis character, and report close candidate matches on failure.

**Priority:** Medium

### 9. Tap success did not indicate whether state changed

**Observed:** Tapping disabled model options returned `ok`, although the selected model did not change and the menu remained open.

**Expected:** Distinguish among event delivery, disabled controls, unchanged state, successful selection, and completed navigation.

**Suggested statuses:** `disabled`, `not_hittable`, `no_effect`, `state_changed`, and `navigation_completed`.

**Priority:** High

### 10. Screen titles were unreliable

**Observed:** The Messages screen was frequently identified as `HISTORY`, and the first screen after login was temporarily identified as `Unknown`.

**Expected:** Use stable navigation titles or another reliable screen identity and report when the hierarchy is still settling.

**Priority:** Medium

## Product Limitations

### 11. No explicit simulator selection

Multiple iPhone 17 and iPhone 17 Pro simulators existed, but the exposed Tapp tools did not accept a simulator name or UDID. Tapp repeatedly selected a different simulator from the one used by the build command.

**Recommendation:** Add an optional `udid` or `device` argument to build, open, QA, and screenshot operations.

### 12. No wait-for-settled-state operation

Cloud reloads and post-login navigation can briefly produce incomplete accessibility trees.

**Recommendation:** Add a wait operation supporting conditions such as title, visible element, element enabled state, tree stability, or network-idle approximation.

### 13. Disabled state was not prominent in summaries

Controls were listed as available actions even when they were disabled. This initially made an intentionally unavailable model option look like a broken picker.

**Recommendation:** Include `enabled`, `selected`, `hittable`, and `value` in concise control summaries.

### 14. Accessibility lookup errors lacked candidate information

A failed lookup did not show close labels, accessibility identifiers, or normalization details.

**Recommendation:** Return the nearest candidate controls and explain why each did not match.

### 15. No controlled app-data and Keychain test operations

Cross-install and credential-restoration tests need intentional control over app container data and Keychain state.

**Recommendation:** Provide explicit operations for reinstalling while preserving or clearing app data, plus clear warnings for destructive actions.

### 16. Secure credential entry should bypass the model by default

`tapp_ios_login` accepts inline credentials. Although a secure user-entry flow exists, it is not enforced when credentials are already present in conversation context.

**Recommendation:** Default credential fields to direct user-to-tool entry and avoid returning secret values in tool results.

### 17. Recording support was advertised but unavailable

Tool responses repeatedly recommended `tapp_flow_save`, but that operation was not exposed in the session.

**Recommendation:** Expose recording controls consistently or omit that instruction when unavailable.

### 18. Focused authenticated QA needs better constraints

The autonomous QA runner did not offer an obvious way to inject an authenticated session, limit exploration to a particular journey, or prohibit destructive actions.

**Recommendation:** Support focused scenarios with authentication setup, allowed screens/actions, destructive-action policy, and explicit assertions.

## API And UX Concerns

### Hidden launch semantics

It was unclear whether opening an app would install, terminate, relaunch, foreground, or attach to the existing process. These distinctions are essential for lifecycle testing.

### Accessibility and screenshot disagreement

When the accessibility tree and screenshot represented different screens, Tapp did not flag the inconsistency. Important assertions required manual screenshot verification.

### Input delivery was treated as outcome success

`Tapped - ok` generally meant an input event was sent, not that the intended outcome occurred. Test evidence should distinguish action delivery from assertion success.

### Session continuity was weak

Starting another Tapp session discarded interaction context and could restart the app, making multi-stage lifecycle scenarios difficult to test reliably.

### Auto-detection was overconfident

When several Xcode containers or simulators were plausible, Tapp guessed instead of returning choices. Explicit target selection would have been faster and safer.

## Highest-Priority Improvements

1. Expose simulator boot and simulator selection by UDID.
2. Add a non-terminating attach/foreground mode.
3. Return complete build diagnostics and log paths.
4. Detect stale accessibility trees when the app is backgrounded.
5. Report disabled and no-effect actions accurately.
6. Keep documented, recommended, and exposed tool names aligned.
7. Improve Xcode container and scheme discovery.
8. Make secure credential injection bypass the model by default.
9. Expose recording and focused-flow tools consistently.
10. Add outcome assertions instead of treating input delivery as success.

## Positive Observations

- Accessibility summaries made basic navigation fast when labels were stable.
- Screenshots were valuable for catching stale or misleading accessibility results.
- `tapp_ios_login` handled iOS secure-field behavior more reliably than manual typing.
- Destructive confirmation UI could be validated safely by opening the dialog and canceling.
- Passing a compiled `.app` provided a practical fallback when project build detection failed.
