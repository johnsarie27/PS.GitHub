# ADR 8: Determinism-vs-Knowledge as an Export-Surface Criterion

## Status

Accepted

## Context

[ADR-3](0003-rejected-function-scope.md) established an **incident-driven
bar for adding functions to the module**: speculative "this seems useful"
additions are declined; a candidate helper needs a documented recurring
miss (or an external caller with a real use case the current surface
cannot express) before it earns a slot in `FunctionsToExport`. That axis
answers the *"is the mistake real?"* question well.

It does not, on its own, answer a second question that surfaced during
[issue #12](https://github.com/johnsarie27/PS.GitHub/issues/12) after
v0.1.0 shipped: **once a mistake is real, is a shipped function the right
form of intervention for it, or is a documented skill rule sufficient?**

The framing in issue #12 borrows from Anthropic's
["How we use Skills"](https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills)
post: giving an agent code (as opposed to prose) is most valuable when
the code enforces something the agent reliably gets wrong by
composition — a stateful side effect, a run-time invariant, or a fiddly
parse the model would regenerate slightly differently each time. When
the *only* thing a helper offers is a fact ("use endpoint A, not
endpoint B"), a well-placed prose rule in the `pwsh-cli-json` skill
delivers the same corrective at author time without adding a run-time
surface every consumer must remember exists.

The four v0.1.0 functions are not homogeneous under this second lens:

- **`New-GhBody`** — determinism. `try` / `finally` around the temp file
  is a run-time invariant a caller cannot obtain from a document. If the
  caller forgets, the file leaks. This is the textbook case for shipping
  code.
- **`Test-GhAuthScope`** — determinism. Parsing `gh auth status` output
  (quoted-vs-bare scope list, exact-match to prevent `admin` false-matching
  `admin:org`, remediation-string construction) is fiddly logic that would
  be regenerated slightly wrong each time. A tested function beats a
  regenerated regex.
- **`Invoke-GhApi`** — determinism plus substrate. Silent-404, empty-204
  short-circuit, `--paginate` delegation, `-Body` piping through stdin,
  preference isolation, and `string[]` normalization together form
  behavior a caller cannot get from prose. It also serves as the base for
  `New-GhBody`-adjacent workflows and for `Resolve-GhCommitSha`, plus
  callers who genuinely want the silent-404 / empty-204 handling.
- **`Resolve-GhCommitSha`** — the weakest case. Its primary value is
  *knowledge*: use `GET /repos/{owner}/{repo}/commits/{ref}` (not
  `/git/refs/tags/{ref}`) to avoid the annotated-tag-object trap. Once
  the caller knows that, `(Invoke-GhApi -Path "repos/$o/$r/commits/$Ref").sha`
  is a one-liner. There is a secondary run-time component in
  `-CrossCheck` (fetch both endpoints, compare, `Write-Warning` on
  disagreement) that is genuinely composable-wrong, but the primary read
  path is knowledge that already lives in the `pwsh-cli-json` skill.

Two possible responses to that grading were considered:

- **A. Prune `Resolve-GhCommitSha` from the module.** Remove the export
  in v0.2.0, keep the knowledge in the skill. Aligns the export surface
  with the determinism principle strictly. But: v0.1.0 already advertised
  the four functions publicly; a search for callers turned up zero real
  consumers, so no deprecation cycle is forced, but by the same argument
  no external forcing function pushes a removal either. ADR-3's
  incident-driven bar for the *inverse* direction (removals) would ask
  for an incident where the function's presence caused harm, and none
  has been observed.
- **B. Record the principle, grade the existing functions against it,
  and use it as a forward-looking criterion for future proposals.**
  Existing functions are audited, not evicted. `Resolve-GhCommitSha` is
  graded down (`Status: Beta`) with an explicit note that it is the
  weakest determinism case, subject to reconsideration if a concrete
  misuse or maintenance burden surfaces. Future proposals must answer
  the determinism question before landing.

Shape **B** preserves both the module's incident-driven governance and
the article's principled framing without churning the v0.1.0 export
surface for a taste refinement.

## Decision

We adopt a **determinism-vs-knowledge** test as a second axis (alongside
ADR-3's incident-driven axis) for judging what belongs in
`FunctionsToExport`:

> A helper earns a slot in the module when its primary value is
> *determinism* — enforcing a stateful side effect, a run-time
> invariant, or a fiddly parse the model would regenerate slightly wrong
> each time. Helpers whose primary value is *knowledge* — a fact that,
> once told, produces a trivial one-liner — belong in the
> `pwsh-cli-json` skill (or another author-time surface), not the
> module. Both sources of value can coexist in a single helper; this is
> a primary-value test, not an exclusion test.

Every new function proposal must answer, in its issue or PR description:
"What determinism does this add that a skill rule cannot teach?" A weak
answer is not a hard reject, but it must be surfaced in review and
weighed alongside ADR-3's incident question.

Applied retroactively as an **audit**, not a mandate:

| Function | Primary value | Disposition |
| --- | --- | --- |
| `New-GhBody` | Determinism (temp-file lifecycle invariant) | Keep. `Status: Stable`. |
| `Test-GhAuthScope` | Determinism (`gh auth status` parse + remediation) | Keep. `Status: Stable`. |
| `Invoke-GhApi` | Determinism (silent-404, empty-204, preference isolation, normalization) + substrate | Keep. `Status: Stable`. |
| `Resolve-GhCommitSha` | Knowledge-primary, small `-CrossCheck` determinism component | Keep. `Status: Beta` with a `.NOTES` note pointing at this ADR and stating that removal is on the table if a concrete misuse or maintenance burden surfaces. |

This ADR **supersedes ADR-3 in part**: ADR-3's specific rejections
(`Invoke-GhWrite`, `Assert-GhEndpoint`, `Get-GhPaginated`, subcommand
wrappers) remain valid and remain grounded in the incident-driven axis.
The determinism-vs-knowledge axis is additive; a helper must clear both
bars to earn a slot.

## Consequences

Positive:

- Future function proposals answer a sharper question. "Is this real?"
  (ADR-3) and "Is this determinism?" (this ADR) together form a
  two-axis screen that filters out both speculative additions and
  well-motivated-but-knowledge-shaped additions.
- The `pwsh-cli-json` skill gains explicit standing as the correct home
  for pure-knowledge corrections. Contributors who observe an
  agent-recurrent factual miss (endpoint-shape choice, header
  requirement, docs page to consult) know to open a skill PR rather
  than a module PR.
- The v0.1.0 export surface is preserved. No consumers churn.
  `Resolve-GhCommitSha`'s `Status: Beta` signals softer support without
  breaking anyone.

Negative:

- The line between "knowledge" and "determinism" is judgment, not a
  bright rule. A helper that runs three API calls, compares them, and
  emits a structured warning sits on the boundary — reviewers will
  disagree. This ADR does not attempt a formal metric; it names the
  question and expects the answer to be argued in issue/PR text.
- `Resolve-GhCommitSha` sits in a mildly awkward state: graded down but
  retained. A future reader may find that inconsistency surprising.
  The `.NOTES` cross-reference to this ADR is the mitigation.

Neutral:

- The threshold for reopening `Resolve-GhCommitSha`'s disposition is
  now explicit: a documented incident where the function's presence
  caused harm (misled a caller into the wrong endpoint, imposed a
  maintenance cost the skill rule would not have), *or* an unrelated
  breaking change in v0.2.0 that makes a same-release removal
  incrementally cheap. Absent either, the retention decision stands.
- No manifest bump is required for this ADR. Landing the ADR plus the
  `Resolve-GhCommitSha` `.NOTES` grade is a docs-only change and rolls
  into the next scheduled release notes.
