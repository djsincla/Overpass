# Overpass

An iOS, iPadOS and macOS satellite tracker that drives iOptron mounts. Work on a branch and open a pull request; the user merges.

## Releases with atk

`atk` is the App Store Connect and TestFlight tool in `~/.local/bin/atk`. Its source is in github.com/djsincla/apple-toolkit, and `make install` there updates it. The project's settings are in `.atk.json`. Bundle ID: `com.dwaynesinclair.overpass` (iPhone, iPad and Mac are one App Store app, "Overpass AB6A"). Tester group: `Field testers`.

### Rules

- **atk does every release and App Store step.** Don't rebuild the steps by hand with xcodebuild, notarytool, gh or scripts against the App Store Connect API. If atk can't do something, add it to atk: a branch and a pull request in apple-toolkit, with tests and a line in this guide. Then use it.
- **Don't poll.** A launchd watch reports review decisions with a notification. When the user asks where things stand, run `atk` once. Don't schedule checks from the session.
- **Run commands plainly.** `atk check` and `atk doctor` exit non-zero when something is missing. Piping them through `tail` or `head` hides that, so read the whole output; it's short.
- **The API key's `.p8`** lives in `~/.appstoreconnect/private_keys`. It never goes in a repository, a message or a log. `.atk.json` holds nothing secret and is committed.

### Commands, by what they touch

**Read only: run freely.**

| Question | Run |
| --- | --- |
| Where does everything stand? | `atk` (builds by platform with their TestFlight state, each platform's App Store version with its build and review state, the groups, whether the watch is on) |
| Would a release work? | `atk doctor` (every check, no building; about 30 s, or `--quick`) |
| What will testers be asked to test? | `atk notes` |
| What does App Review still need, or where does a submitted version stand? | `atk check` (`--platform ios` or `macos`) |
| Who's testing? | `atk testers` |
| What would a change do? | `--dry-run` on `ship`, `submit`, `listing push` and `screenshots push` |

**Changes App Store Connect: show the dry run, then go ahead if the user's request covers it.**

| To | Run |
| --- | --- |
| Send the listing text and version number | `atk listing pull` to `appstore/listing.json`, edit, `atk listing push` |
| Take the screenshots | `atk screenshots capture` (simulators, and "Mac" for the Mac App Store) |
| Make the product page header and search picture | `atk screenshots header` (from `screenshots.header` in `.atk.json`) |
| Upload the screenshots and header | `atk screenshots push` (replaces the pictures on the version) |
| Put a build on the App Store version | `atk attach` (`ship` does it itself) |
| Send an uploaded build to testers | `atk release N` (both platforms' build N; `--platform` for one). This submits to Beta App Review |

**Public, irreversible or seen by people: only when the user asks for exactly this.**

| To | Run |
| --- | --- |
| Release | `atk ship`. It uploads to Apple, pushes a tag and publishes a GitHub release |
| Submit for App Review | `atk submit` |
| Withdraw from App Review | `atk cancel --platform ios` |
| Retire builds | `atk expire N…`. It expires build N on every platform, and can't be undone. `--force` takes a build from testers using it |
| Invite a tester | `atk invite EMAIL`. This emails them |

If the session's permission settings deny one of these after the user said yes, ask them to run it as `! atk …`.

### Build numbers

An iOS build and a macOS build of one release share a build number, so `atk` shows two rows for build 18 with a Platform column. `release`, `expire` and the watch treat them as two builds. The Mac App Store build only exists when `"macAppStore": true`; without it the Mac ships only as the DMG.

### Shipping a release

1. In a release pull request, raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, along with the version history if the project keeps one. Get it merged.
2. Every pull request body has a `Tests:` section: numbered steps, each saying what to do and what the tester should see. For example: `1. Open Settings and turn on Dark mode. The sky view turns red.` `ship` gathers them from the pull requests merged since the build testers have, and makes them the What to Test notes. A version bump needs none. Anything fixed or changed needs a step.
3. On an up-to-date main, run `atk doctor`. Fix anything marked ✗.
4. Run `atk ship` in the background and wait for it to finish; it takes 10 to 30 minutes. It does the following:
   - uploads iOS
   - makes and notarises the DMG
   - uploads the Mac App Store build when that's on
   - tags `vX.Y.Z` and publishes the GitHub release
   - sends each uploaded build to testers and submits them to Beta App Review
   - attaches the builds to the App Store versions being prepared
   - turns on the watch
5. If it stops partway, read the error and the log it names. Logs are in `~/Library/Caches/atk/<bundle id>/<version>-<build>/`. Fix the cause, then run it again, leaving out the steps already done with `--no-ios`, `--no-mac`, `--no-dmg`, `--no-mac-app-store`, `--no-github` or `--no-testflight`.
6. Give the user the DMG (send the file), the GitHub release link, and the TestFlight public link with the build's review state.

### Submitting to the App Store

1. The version number comes from `"version"` in `appstore/listing.json`. Change it there and run `atk listing push`; this renames the version being prepared and keeps its text and screenshots.
2. `ship` attaches each platform's build. If it warns that the App Store version has a different number, do step 1, then `atk attach`.
3. Run `atk check` and fix what it lists, with `listing push`, `screenshots push`, or the website for what the API can't reach (see below).
4. When the user asks to submit, show `atk submit --dry-run`, then run `atk submit`. It submits each platform's version and reads the state back.
5. The watch reports App Review's decision. `atk` and `atk check` show the state on demand.

**To change the build or number after submitting:** have the user run `atk cancel --platform …`, or ask first and run it yourself. Then change the build or number, `atk attach`, `atk check` and `atk submit`.

**Rejected:** `atk check` starts with the link to App Review's page in App Store Connect. Apple's reasons aren't in the API, so ask the user to paste them. Fix the problem, ship a new build if the code changed, then `atk check` and `atk submit`.

### When something goes wrong

| You see | Do |
| --- | --- |
| "Xcode's Apple ID sign-in has lapsed or is missing", or "Failed to Use Accounts" | Only the user can fix it: Xcode, Settings, Accounts, sign in. Then run `ship` again with the `--no-…` flags for steps already done |
| A network error or timeout during `submit`, `push` or `release` | Run `atk check` or `atk` to see whether it went through, then run the same command again. They pick up where things stand rather than doing it twice |
| `check` shows no open submission, but the user pressed Submit in the website | Trust `check`: a press there has gone unregistered before. Run `atk submit` once the user agrees |
| The build hasn't appeared, or is still processing | `ship` and `release` wait for it, up to `--timeout` minutes; `attach` doesn't, so run it once `atk` shows the build processed |
| atk won't build after an Xcode update | In apple-toolkit, `rm -rf .build` and `make install`. If it's the Xcode licence, the user runs `! sudo xcodebuild -license accept` |
| A state name you don't recognise | Apple renames states. atk prints them as App Store Connect gives them; describe that to the user, don't guess |

### What the API can't see or change

Don't keep asking the user about these:

- **App Privacy answers and accessibility declarations:** the website only, which `check` says.
- **App Review's rejection reasons (the Resolution Center):** the website only.
- **"Available in new territories":** the API sets it only when availability is first made, and the website may not show it. Keep `availableInNewTerritories` in `listing.json` the way App Store Connect has it.
- **Requests made through Apple's forms, such as a DriverKit entitlement:** `atk request add` tracks them by watching the bundle ID's capabilities.

### The screenshot test

`atk screenshots capture` runs a UI test from the project on each device in `screenshots.devices`. When writing that test:

- **iPhone and iPad:** save `XCUIScreen.main.screenshot()`. atk sets the 9:41 status bar and dark mode first.
- **Mac ("Mac" in the devices):** have the app size its window to 1440 × 900 points when launched for screenshots, and save `app.windows.firstMatch.screenshot()`. That gives 2880 × 1800, the size the Mac App Store takes. On macOS:
  - toolbar tabs need a coordinate click (`element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()`)
  - list and outline rows are Buttons whose labels carry the row's text
  - keep `addUIInterruptionMonitor` to iOS, where XCTest's check for it can time out
- **Foldables, such as iPhone Duo:** save the window, not the screen, at exactly one of the display type's sizes (2007 × 2853 unfolded). atk accepts it either way up.

### A new project

```
atk apps                                              # the apps on the account, with bundle IDs
atk init --bundle-id com.example.app --group "Testers"
```

Add to `.atk.json` what `ship` can't work out:

- `"generate": "xcodegen -q"` if the project is generated
- `"scheme"` if the scheme isn't named after the project
- `"platforms": ["ios"]` to skip the DMG
- `"macAppStore": true` to upload the Mac build to App Store Connect as well. This needs a sandboxed build, with `com.apple.security.app-sandbox` in the entitlements. A Mac app with the iPhone and iPad app's bundle ID is one App Store listing and one purchase
- `"dmgName"` if the DMG shouldn't take the product name

Commit `.atk.json`, then run `atk doctor`.
