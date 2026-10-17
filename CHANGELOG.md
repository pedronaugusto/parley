# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `wire`: JSON-RPC 2.0 as MCP speaks it. `decode` reads a message's envelope and tells a request, a notification, a result and an error apart, leaving `params` and `result` as their bytes; a refusal names its code and, when it could be read, the id. `writeRequest`, `writeNotification`, `writeResult` (and `beginResult`/`endResult` around a result written in place) and `writeFailure`.
- `Revision`: the protocol revisions parley speaks.

[Unreleased]: https://github.com/pedronaugusto/parley/commits/main
