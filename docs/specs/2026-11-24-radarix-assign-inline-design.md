# Radarix 1.2: assign to me, inline description. Design

Status: approved by the owner ("passt so"), 2026-11-24. Base: Radarix 1.1.0.
Builds on `2026-11-24-radarix-refinements-design.md` (description window).

## Intent

- **Assign:** The owner wants to take or drop an item without opening github.com. A button assigns or unassigns them.
- **Inline description:** Some owners prefer to read the description right in the inspector rather than in a separate window, so this becomes a setting.

This is the first time Radarix writes to GitHub. The writes are limited to the
viewer's own assignment on a single item.

## Goals

1. A setting under **Settings → General**: "Show description" with the
   options "In a window" (the default, as in 1.1) and "In the sidebar".
2. A button **"Assign to me"** / **"Unassign me"**. It appears in the
   inspector, in the description window and in the item context menu.
4. **"Start in the background"** and **"Hide from the Dock when the window is
   closed"** settings (section 3).
5. **Only one Radarix runs per user** (section 4).
3. **Product docs and website, published:**
   - the noix-docs branch `docs/radarix` (1.0, 1.1 and these changes) is merged into `main` and pushed;
   - then the noix.dev branch `radarix` gets `docs: https://docs.noix.dev/radarix/` and is merged into `main` and pushed.
   - Deploying through Portainer is the owner's step.

## Non-goals

- Assigning other people, or choosing the account to assign as.
- Labels, comments, closing or any other write.
- Reviewer requests.

## Anti-goals

The design has failed if:

- Radarix shows an assignment that GitHub did not accept;
- a write uses an account other than the repo's owning account;
- the inline view weakens the description window's protections: JavaScript
  off, a non-persistent store, only the first load in view, http(s) clicks
  opening in the browser, and the CSP.

## Design

### 1. Inline description

- `AppSettings.descriptionPlacement: DescriptionPlacement`, with the cases
  `.window` (default) and `.sidebar`. It decodes tolerantly.
- With `.sidebar`, `ItemDetail` shows the rendered description below the
  details. It reuses the window's load/excerpt/error/"Try again" content and
  `DescriptionWebView` as they are, extracted into one shared view.
  - It loads when the selection changes. Cancel the previous load.
  - The "Show description" button becomes "Open in window".
- Space and the context menu open the window in both modes.
- With `.window`, the behaviour is exactly that of 1.1.

### 2. Assign / unassign

- **Kit API:**
  - `GitHubAPI.setAssigned(_ assigned: Bool, login: String, number: Int, in repo: RepoRef) async throws -> [String]`.
  - It calls `POST` (assign) or `DELETE` (unassign) on
    `/repos/{owner}/{name}/issues/{number}/assignees` with the body
    `{"assignees":[login]}`, and returns the issue's resulting assignee logins.
  - `GitHubClient` gets a general way to send a method with a JSON body, with
    the same headers, error mapping and rate-limit tracking. It stores no
    ETag. It sends no token anywhere but the existing `baseURL`.
- **GitHub drops it silently.** GitHub answers 201 but leaves the assignee
  out when the user lacks push access. If the returned list does not reflect
  the request, the call throws `AssignError.notPermitted`.
- **Errors:** a 403 or 404 also maps to `.notPermitted`. Other errors keep
  their `GitHubError`.
- **Controller:**
  - `RadarixController.setAssigned(_ assigned: Bool, key: ItemKey) async throws`.
  - It uses the owning session and that session's login.
  - On success it writes the returned assignees into the stored record, saves
    it and rewrites the snapshot.
  - It throws `AssignError.noOwner` when no session owns the repo.
- **Attention:** the item's attention is left unchanged. The existing activity
  probe already treats the viewer's own changes as not "updated".
- **UI:**
  - The button reads "Assign to me" when the owning login is not among the
    assignees, and "Unassign me" when it is.
  - While a request runs, the button is disabled and shows a small progress
    indicator.
  - On `.notPermitted`, show "This sign-in can't assign. A fine-grained token
    needs write access to issues and pull requests."
  - Other errors use `AppModel.message(for:)`.
- **Sign-in hint:** the token hint in Account settings adds that assigning
  needs write access (classic: `repo`, fine-grained: write access to issues
  and pull requests).

### 3. Background start and menu bar only (owner, added: "im Hintergrund starten … X minimiert in die Topbar")

What exists: "Open at login" starts Radarix at login without a window. Closing
the main window keeps the app running in the menu bar, but the Dock icon
stays.

- **"Start in the background"** (`AppSettings.startInBackground: Bool`,
  default `false`).
  - When on, no launch opens the main window, at login or not. The menu bar
    item opens it.
  - It plugs into `AppModel.claimLaunchWindow()`, which returns false when the
    setting is on.
  - A launch for a `radarix://` link or a notification click still shows its
    window.
- **"Hide from the Dock when the window is closed"**
  (`AppSettings.menuBarOnlyWhenClosed: Bool`, default `false`).
  - When on, closing the last Radarix window (main or description; Settings
    counts as a window too) switches the app to the accessory activation
    policy. The Dock icon goes, the menu bar item stays.
  - Opening any Radarix window switches back to regular.
  - Turning the setting off while hidden restores the Dock icon right away.
- Both go under Settings → General, next to "Open at login". Both settings
  decode tolerantly.

### 4. One instance per user (owner, added: "nur eine Instanz … nicht mehrere pro User")

- macOS already refuses to launch the same app bundle twice. Two copies at
  different paths still run side by side, for example a development build
  and `/Applications/Radarix.app`. They share the bundle id, so they share the
  data and the menu bar.
- **What happens on launch:**
  - In `applicationWillFinishLaunching`, Radarix looks for another running
    application in this user session with the same bundle identifier and a
    different process id.
  - If it finds one, it hands over to it: it reopens that instance so its
    main window shows, as a Dock click would, and then terminates itself
    before syncing or writing anything.
- **What it must not do:**
  - It never starts a second scheduler.
  - It never writes settings or the snapshot.
- The check is per user session. Other users on the same Mac are not
  affected.
- Do not use `LSMultipleInstancesProhibited`. That key acts across user
  sessions, not per user.

## Calls made (not the owner's words)

- Both new switches default to off, so a 1.1 user notices nothing until they
  turn them on.
- Under "menu bar only", the description windows and Settings count as
  windows. The Dock icon goes only when no Radarix window is open.

- The default placement is "In a window", so nothing changes for existing
  users.
- The button sits in three places: inspector, window and context menu.
- No optimistic update. The UI changes only after GitHub confirms.

## Left to the builder

- The placement of the button within each view.
- The exact layout of the inline section.
