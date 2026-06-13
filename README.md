# magit-forge-plugins

A collection of plugins to improve [`forge`](https://github.com/magit/forge).
The `magit` maintainer is difficult to work with, so I'll be my own dictator.

# Usage

```elisp
(require 'magit-forge-plugins)
```

Each plugin installs its advice at load time.  Set a plugin's flag
variable to `t` to activate it:

```elisp
(setq forge-plugin-topic-format-enable t)
```

With `use-package`:

```elisp
(use-package magit-forge-plugins
  :custom
  forge-plugin-topic-format-enable t)
```

You can also enable a plugin via Customize or its `-enable` function.

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
