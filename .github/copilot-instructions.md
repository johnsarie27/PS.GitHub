# Copilot / AI-agent instructions

Read [AGENTS.md](../AGENTS.md) at the repo root — it contains the working
conventions, cross-cutting rules, layout, and skill/instruction pointers for
this module. This file exists so VS Code Copilot picks up the guidance
automatically when working inside this repo.

Quick summary:

- Purpose: small, portable PowerShell helpers wrapping `gh` and the GitHub REST
  API, targeting the mistakes with **stateful side effects** that author-time
  guidance cannot prevent (temp-body-file litter, missing OAuth scopes surfacing
  as opaque 404s, tag-object vs commit-SHA).
- Current work-in-progress: v0.1.0. Plan is in
  [`docs/PLAN.md`](../docs/PLAN.md). Umbrella issue is
  [#1](https://github.com/johnsarie27/PS.GitHub/issues/1).
- Four cross-cutting rules every public function honors:
  `$PSNativeCommandUseErrorActionPreference` isolation, `string[]`
  normalization at the boundary, no `--jq`/`--query` for filter/project,
  temp-body lifecycle owned by `New-GhBody` (not the caller).
- Branch per PR (`<issue>-<slug>`); commit messages `action: scope (refs #N)`;
  no direct commits to `main` except doc-only work that has been agreed
  in-conversation.
- GitHub bodies: **one paragraph per line**, never hard-wrap.

Full context in [AGENTS.md](../AGENTS.md).
