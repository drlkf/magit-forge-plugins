# magit-forge-plugins

You are building a MELPA package containing plugins for Emacs'
[`magit-forge`](https://github.com/magit/forge/) package. You should integrate
with `forge`'s facilities as much as possible. Make sure to pull any required
dependency beyond `forge` in the package metadata.

Each plugin should have its customizable flag to enable it, `nil` by default,
which if set will trigger the associated `-enable` user-callable function to
enable that specific feature.
They should also have one `tested-on-forge` constant containing the `forge`
version they were implemented against. Make sure to fill them with the locally
available versions you used to verify their implementation.

# Forge interactions

Only implement specific forges implementations when prompted by the developer,
otherwise only implement the scaffold.

When implementing specific forges, use the same API facilities as the `forge`
package e.g `ghub` for Github; refer to up-to-date `forge` sources to find them
out.

# Documentation

You should document every feature in the `README.md`, with their associated
section describing their feature flag and available customizations. Make sure to
include the `tested-on-forge` value at the top of the section too.

# Conventions

The global package prefix is `forge-plugin`:

- a public variable `frobnicate-method` should be `forge-plugin-frobnicate-method`
- a private variable `frobnicate-parameters` should be `forge-plugin--frobnicate-parameters`

If modifications to upstream `forge` behavior must happen, make sure to use
`advice-add` instead of overwriting the original symbols with custom code.
