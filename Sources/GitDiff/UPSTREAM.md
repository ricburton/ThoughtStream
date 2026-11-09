Vendored parser and models from https://github.com/tornikegomareli/gitdiff (MIT).
Retrieved 2026-10-24 through the GitHub connector.

Upstream Git blob identifiers:
DiffParser.swift: 5ff09ac57805eb526221c242f5c650e1eab042fc
DiffParsing.swift: 5a974664f0c91b4f84e411308d92d213e99010ec
DiffFile.swift: 8cf2d4f486b0323921f72c840341573ed0b1f67a
DiffHunk.swift: 56e2e537dd12fb0974418dab854755b07cadfdf2
DiffLine.swift: a11720333ac1cfb6ddc1f69472fab4846280550a

Local changes: parsing is synchronous for the native feed render pipeline;
Git's no-newline marker is metadata and does not advance line numbers.
The SwiftUI renderer is not included. LICENSE is bundled with the app.

