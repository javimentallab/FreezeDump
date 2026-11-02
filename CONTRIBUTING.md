# Contributing

Thanks for your interest. FreezeDump has a single maintainer, so replies can take a while.

## Bugs and ideas

Open an [issue](https://github.com/javimentallab/FreezeDump/issues). Say what you expected, what happened, and which version and system you use. English or Spanish are both fine.

Security problems go through [SECURITY.md](SECURITY.md), not through issues.

## Changing the code

For anything big, open an issue first so we can agree on the approach.

```powershell
./tests/run-tests.ps1
./tests/run-analyzer.ps1   # needs the PSScriptAnalyzer module
```

- **Tests:** anything important that you add comes with a test.
- **Dependencies:** a new one needs a permissive licence (MIT, BSD, Apache…). Check it before adding it.
- **Private data:** no personal paths, hostnames, IP addresses or tokens in the code, the history or the screenshots.
- **Licence:** your contribution is released under the project's [MIT licence](LICENSE).
