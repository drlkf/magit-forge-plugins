# magit-forge-plugins

A collection of plugins to improve [`forge`](https://github.com/magit/forge).
The `magit` maintainer is difficult to work with, so I'll be my own dictator.

# Usage

To use the plugins, require the package, set the desired feature flags to `t`, and call `forge-plugins-enable`:

```elisp
(require 'forge-plugins)

(setq forge-plugins-topic-format-enable t
      forge-plugins-github-actions-enable t
      forge-plugins-pullreq-commits-enable t)

(forge-plugins-enable)
```

With `use-package`:

```elisp
(use-package forge-plugins
  :custom
  (forge-plugins-topic-format-enable t)
  (forge-plugins-github-actions-enable t)
  (forge-plugins-pullreq-commits-enable t)
  :config
  (forge-plugins-enable))
```

# Plugins

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
symbols.  When non-nil, the forge's leading character is replaced
at display time.  Example:

```elisp
(setq forge-plugins-topic-slug-symbols
      '((forge-issue    . "#")
        (forge-pullreq  . "!")
        (forge-discussion . "@")))
```

## GitHub Actions

Display GitHub Actions status on pull request lines and in the topic view, with the ability to view logs and trigger re-runs. The actions are listed under the collapsible `Actions` section (with `TAB`, default expanded), placed directly after the `Commits` section, and each individual action line is fully interactible across its whole width including the indentation. The same summary is also appended to the `Actions` section heading in `forge-pullreq-mode`.

The pull request line indicator is formatted as `(x/y)`, where `x` is the number of successful check runs and `y` is the number of non-skipped check runs, e.g. `(3/4)` for four relevant runs of which three succeeded.

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

- `forge-plugins-github-actions-refresh-delay` -- Delay in seconds (default
`0.3`) before refreshing buffers after a fetch completes. Completions within
this window are coalesced into a single refresh, avoiding the refresh storm
that previously froze the Emacs daemon.

### Keybindings

When inside a pull request topic view, the following keybindings are available on a GitHub Action line:

- `RET` -- Fetch and view the action's job logs directly inside Emacs (logs are cached after the first fetch).
- `b` -- Open the action's logs in your browser.
- `R` -- Trigger a re-run of the action.

When viewing the logs inside Emacs, the following keybindings are available:

- `b` -- Open the action's logs in your browser.
- `r` -- Refresh/revert the logs just-in-time (bypasses the cache and fetches the latest logs).
- `q` -- Bury/quit the log buffer.

## Pull Request Commits

In the pull request buffer, `forge` builds the `Commits` section by unioning several refs (the canonical `refs/pullreqs/N` ref, the active local pull request branch, and a local branch matching the head ref) so the listing stays useful when those refs drift out of sync. A side effect is that, after a force-push or rebase, a local pull request branch that still points at the old commits causes those stale commits to reappear in the section.

This plugin restricts the section to `forge`'s canonical range, `<remote>/<base-ref>..refs/pullreqs/N`, so only the commits actually present in the (re-fetched) pull request are shown. It advises `forge--insert-pullreq-commits` to drop its `all` argument.

**Flag:** `forge-plugins-pullreq-commits-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`
