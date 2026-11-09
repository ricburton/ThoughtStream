# Native feed analysis

The build bundles Node and the locked dependencies in this directory. The Swift
app passes code through stdin to `analyze-code.cjs` in a background service. It
never evaluates the snippet, loads project configuration, or writes source files.

- Python: bundled [Ruff](https://docs.astral.sh/ruff/) formatter and linter.
- JavaScript / JSX: [Prettier](https://prettier.io/docs/api) and
  [ESLint](https://eslint.org/docs/latest/integrate/nodejs-api), recommended rules
  with browser and Node globals. Snippet analysis is not whole-project type checking.
- HTML: Prettier and [HTML Validate](https://html-validate.org/dev/using-api.html),
  recommended rules with the Prettier compatibility preset. A doctype is optional
  because feed content often contains fragments.

Dependencies are version-locked in `package-lock.json`; their licenses ship in
the bundled node_modules. Install with `npm ci --ignore-scripts`.

The native JSON presentation is visually inspired by
[UIW React JSON View](https://github.com/uiwjs/react-json-view)'s GitHub theme:
purple keys, blue values, muted counts, indentation guides and hover rows. No
React or web renderer is used for the JSON feed. All containers stay expanded,
and short scalar maps flow horizontally.
