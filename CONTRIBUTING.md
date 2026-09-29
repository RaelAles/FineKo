# Contributing to FineKo

Thanks for your interest in improving FineKo! This document explains how to
propose changes, report problems, and run the project's checks. Please read it
before opening an issue or a pull request.

## Ways to contribute

- **Report a bug** — open an issue describing the problem and how to reproduce it.
- **Suggest a feature** — open an issue explaining the use case.
- **Fix or improve code** — send a pull request.
- **Translate** — add or review entries in `i18n/translations.py`.
- **Improve documentation** — the READMEs and this file are always welcome to
  clarifications.

## Before you start

- Search the existing issues and pull requests to avoid duplicates.
- For anything larger than a small fix, open an issue first so we can agree on
  the approach before you write code.
- Keep the changes focused. One topic per pull request makes review easier.

## Requirements

- **KOReader** — the plugins run inside KOReader. Install a recent build to
  test your changes.
- **luajit** — used to validate that every Lua file parses. It is available in
  most package managers (`apt install luajit`, `brew install luajit`, ...).
- **Python 3 + gettext (`msgfmt`)** — only needed when you touch translations.

## Repository layout

Each plugin is a folder ending in `.koplugin`, and all three share the same
translation system. See the `README.md` for the full map of the repository.

- `atualizarmetadados.koplugin/` — Update metadata plugin.
- `destaquealeatorio.koplugin/` — Random highlight plugin.
- `estantemosaico.koplugin/` — Mosaic shelf plugin.
- `i18n/` — translation catalog (`translations.py`) and generator (`build.py`).

Each `.koplugin` folder contains a `fineko_i18n.lua` file. **This file is the
same in all three plugins** and must stay byte-identical across them; the
translation generator checks this.

## Development workflow

1. Fork the repository and clone your fork:
   ```bash
   git clone https://github.com/<your-user>/FineKo.git
   cd FineKo
   ```
2. Create a branch with a short, descriptive name:
   ```bash
   git checkout -b fix-random-highlight-crash
   ```
3. Make your changes.
4. Run the checks below.
5. Commit and push, then open a pull request.

## Checks

### Validate the Lua syntax

The release workflow runs this exact check. Run it locally before pushing:

```bash
find . -name '*.lua' -not -path './.git/*' -print0 \
  | while IFS= read -r -d '' f; do
      luajit -e "assert(loadfile('$f'))" || exit 1
    done
```

### Manually test in KOReader

There is no automated test suite for the plugins' behavior. Copy the affected
`.koplugin` folder(s) into KOReader's `plugins` folder, restart KOReader, and
confirm the plugin still loads and behaves as expected.

## Translations

The interface is translated into the 21 languages listed in the README. The
message catalog lives in `i18n/translations.py`. The msgid is the Portuguese
text exactly as it appears in the Lua code, so for `pt` the translation is the
msgid itself.

To change or add a translation:

1. Edit `i18n/translations.py`.
2. Regenerate the catalogs:
   ```bash
   python3 i18n/build.py
   ```
   This requires `msgfmt` (from the gettext package) in the `PATH`. The script
   writes `<plugin>/l10n/<lang>/fineko.po` and `fineko.mo` for the three
   plugins and verifies that the three `fineko_i18n.lua` copies stay identical.
3. Commit both the source catalog and the regenerated files.

## Coding guidelines

- **Lua**, following the style of the surrounding code and of KOReader itself.
- Use existing KOReader APIs and utilities instead of reimplementing them.
- When a message is user-facing, do not hardcode it: add it to
  `i18n/translations.py` and wrap it with the translation helper.
- Keep changes minimal and scoped; avoid unrelated refactors in the same pull
  request.
- Do not rename or move files unless the change requires it.

## Commit messages

FineKo uses [Conventional Commits](https://www.conventionalcommits.org/): a
`type(scope): description` header. The description is written in Portuguese,
matching the existing history.

```
<type>(<scope>): <descrição>
```

Common types:

| Type | Use for |
| --- | --- |
| `feat` | A new feature. |
| `fix` | A bug fix. |
| `perf` | A performance improvement. |
| `refactor` | A change that neither fixes a bug nor adds a feature. |
| `style` | Formatting or visual-only changes. |
| `test` | Tests and test-related changes. |
| `docs` | Documentation. |
| `build` | Build process or external dependencies. |
| `ci` | Continuous integration. |
| `chore` | Routine or maintenance tasks. |
| `revert` | Reverting a previous commit. |

Examples:

```
fix(destaquealeatorio): evita erro quando o sidecar está vazio
docs(README): esclarece o modo mosaico do estantemosaico
```

## Pull request process

1. Make sure the Lua syntax check passes.
2. Describe what the change does and why, and how you tested it.
3. Reference the related issue, if any (for example, `Closes #12`).
4. Keep the pull request focused on a single topic.
5. Be ready to adjust the change based on review feedback.

Maintainers may edit the branch directly or ask for changes. Please be patient
— this is a volunteer-run project.

## Reporting bugs

When opening an issue, please include:

- The plugin(s) affected and their version (release tag or commit).
- Your KOReader version and device.
- Steps to reproduce the problem.
- What you expected and what actually happened.
- Relevant logs or screenshots, if available.

For security problems, **do not** open a public issue; follow `SECURITY.md`.

## Adding a new plugin

If you want to contribute a plugin:

- Create a folder named `<name>.koplugin` with `_meta.lua`, `main.lua`, and the
  shared `fineko_i18n.lua`.
- Use the existing plugins as a reference for structure and conventions.
- Register any new messages in `i18n/translations.py`.
- Update both `README.md` and `README.pt-BR.md`.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
