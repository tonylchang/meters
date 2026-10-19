# Contributing to meters

Issues and pull requests are welcome. meters has a narrow goal, a few signals in a small, quiet panel, so this page explains what fits and how a change is checked before it merges.

## Reporting a bug

Open an issue with:

- your Mac model, chip, and macOS version;
- what you did, what you expected, and what happened;
- for a reading that looks wrong, the value meters showed and what Activity Monitor or a command-line tool such as `top`, `vm_stat`, or `df` showed at the same time.

meters collects no diagnostics, so the details in the issue are all there is to go on.

## Suggesting a feature

Check the README's [Roadmap](README.md#roadmap) and [Limits](README.md#limits) first. Process lists, remote monitoring, fan control, and long-term history are deliberately out of scope. For anything new, open an issue to discuss it before writing code.

## Pull requests

- **Small fixes** can go straight to a pull request.
- **Behavior changes and new features** start with an issue, so the behavior is agreed before code is written. A pull request that changes behavior updates the README's description of it in the same change.
- **Tests**: use Swift Testing. Every metric reads through a protocol, so tests substitute fakes for the system. A bug fix includes a regression test that fails without the fix.
- **Changelog**: add a user-facing line under Unreleased in [CHANGELOG.md](CHANGELOG.md).
- **Checks**: the requirements are the same as in the README's [Build from source](README.md#build-from-source) section. Before opening a pull request, run:

  ```sh
  make lint
  make build
  make test
  make audit
  make smoke
  ```

  Changes to data sources, sampling, or panel drawing also need `make perf`, which runs for five minutes and needs an awake, unlocked display. Include the results in the pull request. `make format` applies the formatting that `make lint` checks, and any compiler warning fails the build, including Swift 6 strict concurrency diagnostics.

## Boundaries

These keep meters small, private, and safe to run. A change that crosses one needs discussion in an issue first:

- network connections, analytics, or crash reporting;
- new entitlements, macOS permission prompts, administrator privileges, or private frameworks;
- third-party dependencies;
- code copied from other projects. Studying their techniques and public documentation is fine.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE), the same license as the rest of meters.
