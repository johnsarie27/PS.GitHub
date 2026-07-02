# ADR 7: Paragraph Handling in `New-GhBody`: Convention Over Enforcement

## Status

Accepted

## Context

[ADR-2](0002-scriptblock-wrapper-for-body-lifecycle.md) established the
`ScriptBlock` wrapper shape for `New-GhBody`. Its Decision section
included the parenthetical claim that the function "creates a temp file
with the **(paragraph-per-line-normalized)** body content". At the time
that ADR was written, the parenthetical was aspirational — it signaled
intent to address the hard-wrap problem described in ADR-2's Context
section, but did not commit to a specific mechanism (reject vs. reflow
vs. document-as-convention).

When implementing `New-GhBody` in PR-C, that unfulfilled parenthetical
forced a real design decision. Three mechanisms were considered:

- **Reject on hard-wrap.** Detect two adjacent non-blank lines inside a
  paragraph and throw a terminating error. The theory is that
  runtime failure teaches the agent to write paragraph-per-line source.
  In practice the runtime failure interrupts the caller's workflow at
  the point of authoring a body, not at the point of the original
  reflex-hard-wrap decision. The agent has to re-run after the fix.
  User-hostile mid-workflow.

- **Reflow on hard-wrap.** Silently join mid-paragraph lines with a
  space, preserving `\n\n` as paragraph separators. Produces the
  correct rendered GitHub output regardless of source shape. The
  complication is that reflow must preserve:

  - Fenced code blocks (```` ``` ````), where line breaks are meaningful.
  - Indented code blocks (four-space or tab indent).
  - List items (lines beginning with `-`, `*`, or `1.`) where each item
    should stay on its own line.
  - Tables (lines beginning with `|`).
  - HTML block elements (`<pre>`, `<table>`, etc.).

  A correct reflow is a small markdown parser. The wrong reflow
  corrupts code blocks in issue and PR bodies.

- **Convention only.** No runtime enforcement, no reflow. `-Text`
  accepts `string` or `string[]`; a `string[]` is joined with `` `n ``
  (one element per line). Documentation and `.EXAMPLE` blocks show the
  intended paragraph-per-element pattern. The API shape guides callers
  toward correct usage without punishing missteps.

The module's stated purpose (see AGENTS.md and issue #1) is to prevent
mistakes with **stateful side effects** — orphaned temp files, missing
OAuth scopes, tag-object SHAs on Actions pins. Hard-wrapped body text is
a *rendering* mistake, not a stateful one. The rendered issue or PR
looks ragged but nothing about the repository is left in a bad state,
and the ragged output is trivially fixable by editing the issue or PR.
It sits in a different severity class than the mistakes the module was
built to prevent.

The parenthetical in ADR-2 was written on the assumption that
"normalization" would be trivial. Implementation revealed that
correctness-preserving reflow is a real project (fence-aware markdown
processing), and that rejection is a poor fit for the caller ergonomics
this module optimizes for.

## Decision

`New-GhBody` in v0.1.0 will implement **convention over enforcement**:

- `-Text` accepts `string` or `string[]`.
- A `string[]` is joined with `` `n `` (one element = one line of the
  body). An empty-string element produces a blank line, which is the
  natural encoding of a paragraph break.
- The body is written to the temp file **exactly as supplied**. No
  reflow, no rejection, no line-level rewriting.
- The intended paragraph-per-element pattern is documented in the
  function's `.EXAMPLE` block, in the module `README`, and in the
  `AGENTS.md` cross-cutting rules section.

This ADR does **not** supersede ADR-2. ADR-2's Decision (the
`ScriptBlock` wrapper shape) stands unchanged; only the aspirational
"paragraph-per-line-normalized" parenthetical in ADR-2 is clarified
here. Future readers should treat ADR-2 + ADR-7 together as the
complete decision record for `New-GhBody`.

## Consequences

Positive:

- `New-GhBody` stays focused on its central value: temp-file lifecycle
  as an uncircumventable resource-disposal pattern.
- Implementation is small: no markdown parsing, no fence detection, no
  reflow rules. The function is trivial to test and easy to review.
- Callers who use `string[]` naturally author paragraph-per-element,
  the shape the API is optimized for. Callers who pass a single
  `string` retain full control over how their body is structured,
  which matters for content containing code fences, tables, or HTML.

Negative:

- A caller who reflex-hard-wraps a here-string at 80 columns and passes
  it as a single `string` will still produce ragged rendered output on
  the GitHub issue or PR. `New-GhBody` does not save them from this
  mistake. The mitigation is caller convention plus documentation, not
  active code.
- Future observation may show that agents still consistently produce
  ragged output despite the documented convention. If that happens,
  supersede this ADR with one that adopts option 1 or option 2 above.
  The threshold for reopening: at least three separate rendered-ragged
  incidents traceable to `New-GhBody` in a rolling three-month window.

Neutral:

- The doorway for a future fence-aware reflow implementation stays
  open. Nothing in the v0.1.0 API precludes adding an opt-in
  `-Normalize` switch later (default `$false` to preserve current
  behavior; `$true` to reflow). That would be a supersession of this
  ADR when and if the evidence justifies the added surface area.
