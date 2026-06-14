# magit-forge-plugins

A collection of plugins to improve [`forge`](https://github.com/magit/forge).
The `magit` maintainer is difficult to work with, so I'll be my own dictator.

# Usage

To use the plugins, require the package, set the desired feature flags to `t`, and call `forge-plugins-enable`:

```elisp
(require 'magit-forge-plugins)

(setq forge-plugin-topic-format-enable t
      forge-plugin-github-actions-enable t)

(forge-plugins-enable)
```

With `use-package`:

```elisp
(use-package magit-forge-plugins
  :custom
  (forge-plugin-topic-format-enable t)
  (forge-plugin-github-actions-enable t)
  :config
  (forge-plugins-enable))
```

# Plugins

## Topic Format

Customize the display of topic lines in `forge` topic and notification lists.

**Flag:** `forge-plugin-topic-format-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Customization

- `forge-plugin-topic-line-format` -- Format string for topic lines.
Supported `%`-sequences:

- `%R` -- repository slug, padded to `forge-topic-repository-slug-width`
- `%s` -- topic slug (e.g., `#123`), padded
- `%a` -- topic author login
- `%t` -- topic title

Default: `%R%s %t`

- `forge-plugin-topic-slug-symbols` -- Alist mapping topic classes
(`forge-issue`, `forge-pullreq`, `forge-discussion`) to prefix
symbols.  When non-nil, the forge's leading character is replaced
at display time.  Example:

```elisp
(setq forge-plugin-topic-slug-symbols
      '((forge-issue    . "#")
        (forge-pullreq  . "!")
        (forge-discussion . "@")))
```

## GitHub Actions

Display GitHub Actions status on pull request lines and in the topic view, with the ability to view logs and trigger re-runs. The actions section is collapsible with `TAB` (default expanded), and the individual action lines are fully interactible even on their indentation.

**Flag:** `forge-plugin-github-actions-enable` (default `nil`)

**Tested-on-forge:** `0.6.6`

### Customization

- `forge-plugin-github-actions-debug` -- Whether to enable debug logging.
If non-nil, debug logs are written to the buffer `*forge-plugin-github-actions-debug*`.

### Keybindings

When inside a pull request topic view, the following keybindings are available on a GitHub Action section:

- `RET` -- Fetch and view the action's job logs directly inside Emacs (logs are cached after the first fetch).
- `b` -- Open the action's logs in your browser.
- `R` -- Trigger a re-run of the action.

When viewing the logs inside Emacs, the following keybindings are available:

- `b` -- Open the action's logs in your browser.
- `r` -- Refresh/revert the logs just-in-time (bypasses the cache and fetches the latest logs).
- `q` -- Bury/quit the log buffer.
