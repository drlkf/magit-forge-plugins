# magit-forge-plugins

A collection of plugins to improve [`forge`](https://github.com/magit/forge).
The `magit` maintainer is difficult to work with, so I'll be my own dictator.

# Usage

To use the plugins, require the package, set the desired feature flags to `t`, and call `forge-plugins-enable`:

```elisp
(require 'forge-plugins)

(setq forge-plugins-topic-format-enable t
      forge-plugins-github-actions-enable t
      forge-plugins-pullreq-commits-enable t
      forge-plugins-pullreq-approvals-enable t
      forge-plugins-github-projects-enable t
      forge-plugins-github-reviews-enable t
      forge-plugins-github-search-enable t
      forge-plugins-github-teams-enable t)

(forge-plugins-enable)
```

With `use-package`:

```elisp
(use-package forge-plugins
  :custom
  (forge-plugins-topic-format-enable t)
  (forge-plugins-github-actions-enable t)
  (forge-plugins-pullreq-commits-enable t)
  (forge-plugins-pullreq-approvals-enable t)
  (forge-plugins-github-projects-enable t)
  (forge-plugins-github-reviews-enable t)
  (forge-plugins-github-search-enable t)
  (forge-plugins-github-teams-enable t)
  :config
  (forge-plugins-enable))
```

# Plugins

## GitHub Teams

Include GitHub teams in Forge's pull-request review-request prompt. Existing
team requests are read first so replacing the selection does not silently
remove them. GitHub organization teams require a token with the `read:org`
scope; without it, Forge falls back to its normal user-only behavior.

**Flag:** `forge-plugins-github-teams-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Customization

- `forge-plugins-github-teams-debug` -- Whether to enable diagnostic logging.
- `forge-plugins-github-teams-refresh` -- Clear the cached teams for the
  current repository when called interactively.

Requested teams are written correctly but are not currently displayed in
Forge's pull-request header.

## Topic Format

Customize the display of topic lines in `forge` topic and notification lists.

**Flag:** `forge-plugins-topic-format-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Customization

- `forge-plugins-topic-line-format` -- Format string for topic lines.
  Supported `%`-sequences:

- `%R` -- repository slug, padded to `forge-topic-repository-slug-width`

- `%s` -- topic slug (e.g., `#123`), padded

- `%a` -- topic author login

- `%t` -- topic title

Default: `%R%s %t`

- `forge-plugins-topic-slug-symbols` -- Alist mapping topic classes
  (`forge-issue`, `forge-pullreq`, `forge-discussion`) to prefix
  symbols. When non-nil, the forge's leading character is replaced
  at display time. Example:

```elisp
(setq forge-plugins-topic-slug-symbols
      '((forge-issue    . "#")
        (forge-pullreq  . "!")
        (forge-discussion . "@")))
```

## GitHub Actions

Display GitHub Actions status on pull request lines and in the topic view, with the ability to view logs and trigger re-runs. The actions are listed under the collapsible `Actions` section (with `TAB`, default expanded), placed directly after the `Commits` section, and each individual action line is fully interactible across its whole width including the indentation. The same summary is also appended to the `Actions` section heading in `forge-pullreq-mode`.

The pull request line indicator is formatted as `(x/y)`, where `x` is the number of successful check runs and `y` is the total number of check runs, e.g. `(3/4)` for four runs of which three succeeded. Skipped and neutral runs are non-blocking: they are still counted in `y`, but the indicator is faced green as soon as no run has failed and none is still pending, so `(1/3)` for one success plus one skipped and one neutral run renders in the success face.

A pull request whose head revision has not yet been synced (its `head-rev` is `nil`) cannot have its check runs fetched; its `Actions` section shows `not synced — run forge-pull` instead, and (with debug logging enabled) the skip is logged.

When enabling against a `forge` version other than the tested one below, a one-shot, non-fatal warning is emitted via `display-warning`; the feature still enables.

**Flag:** `forge-plugins-github-actions-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Customization

- `forge-plugins-github-actions-debug` -- Whether to enable debug logging.
  If non-nil, debug logs are written to the buffer `*forge-plugins-github-actions-debug*`.

- `forge-plugins-github-actions-max-concurrent-requests` -- Maximum number
  of check-run fetches to run concurrently (default `6`). Fetches are queued
  and dispatched as in-flight requests complete, so status for many pull
  requests is fetched in parallel without blocking Emacs or hammering the
  GitHub API.

- `forge-plugins-github-actions-refresh-delay` -- Throttle window in seconds
  (default `0.3`) for applying fetched results to buffers. In topic-list
  buffers (Magit status, forge topics, notifications) the per-topic status
  badges are patched in place; every completion landing within one window is
  applied in a single section-tree walk and redisplay, so a burst of fetches
  on a large topic list is coalesced instead of triggering one update per
  result. Pull request topic buffers, which carry the full Actions section,
  are refreshed via `magit-refresh` the same way. Lower the value to update
  more eagerly, raise it to coalesce more aggressively. This keeps Emacs
  responsive on repositories with many topics.

### Keybindings

When inside a pull request topic view, the following keybindings are available on a GitHub Action line:

- `RET` -- Fetch and view the action's job logs directly inside Emacs (logs are cached after the first fetch).
- `b` -- Open the action's logs in your browser.
- `R` -- Trigger a re-run of the action.

In both `forge-pullreq-mode` (a pull request topic buffer) and `magit-status-mode`, the following keybinding is available buffer-wide:

- `C-c C-a` -- Refresh the GitHub Actions status, forcing a fresh fetch from the forge. In a pull request buffer this refreshes that pull request; in a status buffer it refreshes every GitHub pull request currently displayed. Unlike magit's `g` (`magit-refresh`), which reuses the cached status as long as the head revision is unchanged, this bypasses the cache and re-fetches the check runs.

The command `forge-plugins-github-actions-clear-queue` (no default keybinding, run via `M-x`) empties the pending check-run fetch queue and resets the dispatch state, to recover if fetches ever get stuck. It also runs automatically when the plugin is disabled.

When viewing the logs inside Emacs, the following keybindings are available:

- `B` -- Open the action's logs in your browser.
- `r` -- Refresh/revert the logs just-in-time (bypasses the cache and fetches the latest logs).
- `q` -- Bury/quit the log buffer.

The log viewer reproduces GitHub's web rendering as closely as possible. It fetches the job's step metadata (`GET /repos/:owner/:repo/actions/jobs/:job_id`) alongside the raw log and partitions the log into one collapsible section per step, named after the step and ordered exactly as the API reports. Lines are assigned to steps by comparing each line's timestamp against the steps' `started_at` boundaries. Each step's heading is faced by its conclusion (success/failure/neutral); successful steps are collapsed by default while failed steps are expanded. Within a step, `##[group]`/`##[endgroup]` blocks render as nested collapsible subsections, nesting arbitrarily deep. If the step metadata cannot be fetched, the viewer falls back to rendering the whole log with nested group sections only.

The runner's other workflow command markers are rendered close to the web UI too: `##[section]` lines are shown as bold section headers, `##[command]` lines are highlighted and prefixed with `>`, and `##[error]`/`##[warning]`/`##[notice]`/`##[debug]` are labelled and faced accordingly. The runner form (`##[...]`) and the action form with fewer or no leading hashes (e.g. `[command]` emitted by `actions/checkout`) are all recognized. The fetched step metadata is cached per job alongside the logs; `r` bypasses both caches and refetches.

Under `evil`, these keys are bound in the motion and normal states so they take precedence over the global vim bindings. `SPC` is left untouched, so any leader key bound to it keeps working, and `b` remains the usual `evil-backward-word-begin` motion.

## Pull Request Commits

In the pull request buffer, `forge` builds the `Commits` section by unioning several refs (the canonical `refs/pullreqs/N` ref, the active local pull request branch, and a local branch matching the head ref) so the listing stays useful when those refs drift out of sync. A side effect is that, after a force-push or rebase, a local pull request branch that still points at the old commits causes those stale commits to reappear in the section.

This plugin restricts the section to `forge`'s canonical range, `<remote>/<base-ref>..refs/pullreqs/N`, so only the commits actually present in the (re-fetched) pull request are shown. It advises `forge--insert-pullreq-commits` to drop its `all` argument.

**Flag:** `forge-plugins-pullreq-commits-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

## Pull Request Approvals

Display the approval status of GitHub pull requests on their topic lines (in topic/notification lists and in the Magit status buffer) and in the pull request topic view. The indicator is formatted as `<x/y>`, where `x` is the current number of approvals and `y` is the number of approvals required by the target branch's rules. For example, if a pull request has three review requests but the branch only requires one approval, and one of them has approved, the indicator shows `<1/1>`.

The current approval count `x` is derived from the pull request's reviews: per reviewer only their latest meaningful review state is considered (a later `COMMENTED` or `PENDING` review does not change it), and an approval is counted when that latest state is `APPROVED`. The required count `y` is read from the target branch's active **rulesets** (`GET /repos/:owner/:repo/rules/branches/:base-ref`), taking the largest `required_approving_review_count` across all `pull_request` rules. When the target branch has no required-approvals rule, the indicator is hidden entirely (even if some approvals exist).

The indicator is faced green (`forge-plugins-pullreq-approvals-met`) once the required number of approvals is reached, and yellow (`forge-plugins-pullreq-approvals-pending`) while it is not. The angle-bracket form `<x/y>` distinguishes it from the GitHub Actions indicator `(x/y)`.

The same summary is appended to a collapsible `Approvals` section (with `TAB`) in `forge-pullreq-mode`, placed directly before the pull request description. Its body lists each reviewer with their latest review state (`approved`, `changes requested` or `dismissed`).

**Flag:** `forge-plugins-pullreq-approvals-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

> **Limitation:** the required approval count is read from rulesets only. Required reviews configured through *classic* branch protection are exposed by GitHub through an admin-only endpoint and are therefore not reflected here.

### Customization

- `forge-plugins-pullreq-approvals-debug` -- Whether to enable debug logging.
  If non-nil, debug logs are written to the buffer `*forge-plugins-pullreq-approvals-debug*`.

- `forge-plugins-pullreq-approvals-max-concurrent-requests` -- Maximum number
  of approvals fetches to run concurrently (default `6`). Fetches are queued and
  dispatched as in-flight requests complete, so status for many pull requests is
  fetched in parallel without blocking Emacs or hammering the GitHub API.

- `forge-plugins-pullreq-approvals-refresh-delay` -- Throttle window in
  seconds (default `0.3`) for applying fetched approvals to buffers. In
  topic-list buffers (Magit status, forge topics, notifications) the
  per-topic approvals badges are patched in place; every completion landing
  within one window is applied in a single section-tree walk and redisplay,
  so a burst of fetches on a large topic list is coalesced instead of
  triggering one update per result. Pull request topic buffers, which carry
  the full Approvals section, are refreshed via `magit-refresh` the same way.
  Lower the value to update more eagerly, raise it to coalesce more
  aggressively. This keeps Emacs responsive on repositories with many topics.

### Keybindings

In both `forge-pullreq-mode` (a pull request topic buffer) and `magit-status-mode`, the following keybinding is available buffer-wide:

- `C-c C-v` -- Refresh the pull request approvals, forcing a fresh fetch from the forge. In a pull request buffer this refreshes that pull request; in a status buffer it refreshes every GitHub pull request currently displayed. Approvals can change without a new push (the head revision is unchanged), in which case magit's `g` (`magit-refresh`) reuses the cached status; this command bypasses the cache and re-fetches the reviews and branch rules.

The command `forge-plugins-pullreq-approvals-clear-queue` (no default keybinding, run via `M-x`) empties the pending approvals fetch queue and resets the dispatch state, to recover if fetches ever get stuck. It also runs automatically when the plugin is disabled.

## GitHub Projects

Read-only viewer for [GitHub Projects v2](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects) — the Kanban-style project boards. `forge` itself models issues, pull requests and discussions, but has no support for Projects v2, which is exposed exclusively through GitHub's GraphQL API (the classic REST Projects API was sunset on 2025-04-01).

Run `M-x forge-plugins-github-projects` from any buffer associated with a GitHub forge repository. It lists the repository's open Projects v2 boards; if there is more than one, you are prompted to pick. The selected board opens in a dedicated `forge-plugins-github-projects-mode` buffer where items are grouped into columns by the board's single-select `Status` field (the field that drives the board columns), in the board's own column order, with a trailing `No Status` bucket for items that have no status value. Each column is a collapsible `magit` section (with `TAB`) whose heading shows the column name and card count. Each card line shows the item's type (`Issue`, `PullRequest` or `DraftIssue`), its number and its title; closed and merged items are dimmed.

Queries and mutations are raw GraphQL POSTed to the `/graphql` endpoint via `ghub-request` (the same primitive `forge` uses), authenticated with `:auth 'forge`, so the repository's existing token and host are reused. Raw GraphQL is required because Projects v2 queries traverse unions and interfaces (`issueOrPullRequest`, `fieldValueByName`, the single-select `Status` field), which need inline fragments that `ghub`'s gsexp query builder cannot express.

**Flag:** `forge-plugins-github-projects-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Topic integration

When enabled, issue and pull request topic buffers gain a collapsible `Projects` section (with `TAB`) that lists the Projects v2 boards the topic belongs to and its status on each (`[no status]` when unset). Membership is fetched asynchronously and cached, so opening a topic never blocks on the network; the section shows `fetching...` until the first fetch completes. `RET` / `b` on a project line opens that project in the browser.

The section is accompanied by a `p` prefix keymap in topic buffers, for acting on the topic's project membership:

- `p a` -- **Add** the topic to a board. Lists the repository's open boards and adds the topic to the chosen one (GraphQL `addProjectV2ItemById`).
- `p s` -- **Set the status** of the topic in a project. If point is on a project line in the `Projects` section, that project is used directly; otherwise you are prompted to pick among the topic's current projects. The project's single-select `Status` options are then offered for completion (GraphQL `updateProjectV2ItemFieldValue`).
- `p r` -- **Remove** the topic from a project, using the same project-selection process as `p s` (GraphQL `deleteProjectV2Item`), after confirmation.

The mutation commands run synchronously (they react to an explicit keypress), then invalidate the cache and refresh the buffer.

> **Keybinding note:** the `p` prefix shadows magit's `magit-section-backward` (previous section) inside topic buffers, as specified. To free `p`, rebind `forge-plugins-github-projects-prefix-map` to another key in `forge-topic-mode-map` instead.

### View-filtered board

**Tested-on-forge:** `0.6.6`

`M-x forge-plugins-github-projects-browse-view` opens a board for any organization or user project — without needing a buffer associated with a repository in that project — and restricts the displayed items to those that match a named view's server-side filter string.

```
M-x forge-plugins-github-projects-browse-view RET
Owner: tsuga-dev RET
Project number: 19 RET
View name: Current Sprint RET
```

The command:

1. Picks any tracked GitHub repository to borrow authentication credentials from (no buffer context required).
1. Resolves the project by owner + number using the GraphQL `organization` root field, with an automatic fallback to `user` when the owner is not an org login. Pass a non-nil `user-owner-p` argument from Lisp to skip the org attempt.
1. Fetches the project's views and finds the named one (case-insensitive match).
1. Parses the view's server-side filter string and builds a local predicate applied before bucketing items into columns.

The resulting buffer is identical to the one opened by `forge-plugins-github-projects` — same mode, same `g` to refresh, same `RET`/`b` to open a card — but shows only items matching the view filter.

#### Supported filter subset

The parser handles the subset of the GitHub Projects filter syntax that drives board columns:

| Token | Effect |
|-------|--------|
| `status:V1,V2,...` | Keep only items whose Status equals one of the listed values (case-insensitive) |
| `-status:V1,V2,...` | Drop items whose Status equals any of the listed values |
| `is:issue` / `-is:pr` | Keep only Issues and Draft Issues (drop Pull Requests) |
| `is:pr` / `-is:issue` | Keep only Pull Requests |

Multi-word status values are quoted in the filter string (e.g. `"In progress"`); the parser strips the quotes and compares case-insensitively. Unsupported tokens (`no:`, `label:`, date ranges, OR-groups) are silently ignored.

### Token scope

Reading Projects v2 requires the `read:project` scope on the token `forge` uses; the `p a`/`p s`/`p r` mutations require the `project` scope. A classic token without the needed scope will get a permission error from the GraphQL API.

### Keybindings

In the board buffer:

- `g` -- Re-fetch and redraw the board.

On a card line (board buffer) or project line (topic `Projects` section):

- `RET` / `b` -- Open the card or project in the browser.

In an issue or pull request topic buffer:

- `p a` -- Add the topic to a project.
- `p s` -- Set the topic's status in a project.
- `p r` -- Remove the topic from a project.

## GitHub Reviews

Integrate GitHub pull request **review threads** — the resolvable, inline code-comment conversations. `forge` models none of this, so everything is fetched and mutated through GitHub's GraphQL API. This is distinct from the [Pull Request Approvals](#pull-request-approvals) plugin, which tracks review *submissions* (`APPROVED`/`CHANGES_REQUESTED`).

Pull request topic lines (in topic/notification lists and the Magit status buffer) and the pull request topic view gain a `{x}` badge, where `x` is the number of **unresolved** review threads (threads whose `isResolved` is false). The badge is faced with `forge-plugins-github-reviews-unresolved` (yellow) and is hidden entirely when every thread is resolved or the pull request has no review threads. The curly-brace form `{x}` distinguishes it from the approvals indicator `<x/y>` and the GitHub Actions indicator `(x/y)`.

Queries and mutations are raw GraphQL POSTed to the `/graphql` endpoint via `ghub-request` (the same primitive `forge` uses), authenticated with `:auth 'forge`, so the repository's existing token and host are reused. Badge reads are asynchronous, queued and cached the same way as the approvals plugin, so opening a topic never blocks on the network; the interaction commands run synchronously in response to a keypress, then invalidate the cache and refresh.

**Flag:** `forge-plugins-github-reviews-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Reviews section

In `forge-pullreq-mode` a collapsible `Reviews` section (with `TAB`) is inserted directly before the pull request description. Its heading carries the same `{x}` badge, and its body lists each review thread as a nested collapsible section headed `path:line [unresolved]` (or `[resolved]`, dimmed and collapsed by default) with a comment count. Each comment line shows its author and the first line of its body; `RET` on a comment visits the commented-on file at its line in the pull request's local worktree, and `b` opens the comment on GitHub.

### Keybindings

In a pull request buffer (`forge-pullreq-mode`), a `v` prefix keymap acts on the review thread or comment at point (or, when point is not on one, prompts among the pull request's threads):

- `v c` -- **Reply** to the thread at point (GraphQL `addPullRequestReviewThreadReply`). The reply body is composed in a `forge` post buffer (`gfm-mode`, submitted with `C-c C-c`), so it behaves like any other `forge` post.
- `v e` -- **Edit** your own comment at point, composed the same way and prefilled with the current body (GraphQL `updatePullRequestReviewComment`). Only comments you authored can be edited.
- `v @` -- **React** to the comment at point, choosing among GitHub's eight reaction emoji (GraphQL `addReaction`).
- `v r` -- **Resolve or unresolve** the thread at point, toggling on its current state (GraphQL `resolveReviewThread` / `unresolveReviewThread`).
- `v g` -- **Refresh** the review threads, forcing a fresh fetch. Reviews change without a new push (the head revision is unchanged), in which case magit's `g` (`magit-refresh`) reuses the cached status; this command bypasses the cache.
- `v ?` -- Show a `transient` menu of the above.

On a comment line in the `Reviews` section:

- `RET` -- Visit the commented-on file at its line in the pull request's local worktree (the file is opened at its beginning when the thread is outdated or file-level and has no line).
- `b` -- Open the comment on GitHub in the browser.

The mutation commands run synchronously, then invalidate the cache and refresh the buffer.

> **Keybinding note:** the `v` prefix shadows magit's `magit-reverse` inside pull request buffers. To free `v`, rebind `forge-plugins-github-reviews-prefix-map` to another key in `forge-pullreq-mode-map` instead.

### Token scope

Reading review threads and reacting requires the `repo` scope (or fine-grained *Pull requests: read*) on the token `forge` uses; replying, editing and resolving require write access (`repo`, or fine-grained *Pull requests: write*). A token without the needed scope will get a permission error from the GraphQL API.

### Customization

- `forge-plugins-github-reviews-debug` -- Whether to enable debug logging. If non-nil, debug logs are written to the buffer `*forge-plugins-github-reviews-debug*`.

- `forge-plugins-github-reviews-max-concurrent-requests` -- Maximum number of review-thread fetches to run concurrently (default `6`). Fetches are queued and dispatched as in-flight requests complete, so status for many pull requests is fetched in parallel without blocking Emacs or hammering the GitHub API.

- `forge-plugins-github-reviews-refresh-delay` -- Throttle window in seconds (default `0.3`) for applying fetched reviews to buffers. In topic-list buffers the per-topic badges are patched in place; every completion landing within one window is applied in a single section-tree walk and redisplay, so a burst of fetches on a large topic list is coalesced. Pull request topic buffers, which carry the full Reviews section, are refreshed the same way. Lower the value to update more eagerly, raise it to coalesce more aggressively.

The command `forge-plugins-github-reviews-clear-queue` (no default keybinding, run via `M-x`) empties the pending review fetch queue and resets the dispatch state, to recover if fetches ever get stuck. It also runs automatically when the plugin is disabled.

## GitHub Search

Read-only viewer for GitHub's [search query syntax](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests) (e.g. `review-requested:@me`, `status:success`, saved-search style queries). `forge` only models topics already synced into its local database, so it cannot filter on live, server-side-only criteria like review-request status or the latest commit's check status; this plugin runs the query string directly against GitHub's search instead.

Run `M-x forge-plugins-github-search` from any buffer associated with a tracked GitHub repository (or any buffer at all, since it only borrows credentials). You are prompted for a search query string, and the matching issues and pull requests open in a flat, read-only `forge-plugins-github-search-mode` buffer, in the order returned by the query (respect a `sort:` qualifier in the query string itself). Each line shows the repository, number, `[draft]` marker (pull requests only) and title; merged and closed items are dimmed.

From Lisp, `forge-plugins-github-search-browse-query` opens the same buffer non-interactively for a hardcoded query string, e.g. to bind a saved search to a key. GitHub has no public API to resolve a saved search (`github.com/pulls/<id>`) by its id, so reproduce its query string manually.

```elisp
(forge-plugins-github-search-browse-query
 "org:my-org is:pr state:open draft:false review-requested:@me sort:updated-desc")
```

Search is a raw GraphQL `search(query:$q, type:ISSUE)` string POSTed to the `/graphql` endpoint via `ghub-request` (the same primitive `forge` uses), authenticated with `:auth 'forge`, so the repository's existing token and host are reused. Raw GraphQL is used for consistency with `forge-plugins-github-projects`, though this particular query does not require inline fragments.

**Flag:** `forge-plugins-github-search-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Token scope

Search requires the same scope as reading the matched items: `repo` (or fine-grained *Pull requests: read* / *Issues: read*) for private repositories, none for public ones.

### Keybindings

In the results buffer:

- `g` -- Re-run the query and redraw the results.

On a result line:

- `RET` / `b` -- Open the item in the browser.
