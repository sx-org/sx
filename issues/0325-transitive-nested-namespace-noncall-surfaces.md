# 0325 — transitive nested namespace aliases on non-call surfaces

> **FOCUSED MATRIX GREEN; ADVERSARIAL REVIEW REOPENED (2026-07-21).** The new
> full-path selector and examples 0908-0910 pass at opt 0/3, but exact target
> selection is not yet applied early enough for every typed store and bare
> type-function author. No public syntax/API change is required.

## Required behavior

For `facade.engine_alias.Member`, prove that `engine_alias` is authored by the
facade target or carried through exactly one of its direct flat imports before
resolving any terminal member. Apply the same target pinning to:

- type annotations and literals;
- constants and enum variants;
- generic struct/type-function heads;
- type/value aliases whose RHS begins with the nested namespace.

A two-flat-edge transitive alias must be rejected; direct and one-hop aliases
must resolve from the exact inner target even when another namespace uses the
same inner alias/member spelling. Add a negative and target-identity positive
for every surface above. No syntax or public API change is required.

## Remaining adversarial findings

- A qualified global is selected only after its RHS has already been lowered.
  `null`, `.variant`, `.{...}`, branch expressions, and multi-assignment can
  therefore inherit caller/unresolved target typing instead of the exact slot.
- Bare type-function gates prove one visible author but still execute the
  process-global function-map winner. Qualified full paths select exactly;
  bare own/one-hop authors need the same declaration-carrying result (also
  tracked with callable aliases in issue 0330).
- The first pre-RHS store repair returned only an optional successful target.
  Missing, ambiguous, immutable, non-lvalue, and not-applicable paths therefore
  collapsed together, and invalid qualified targets could still lower
  target-directed `null`, `.variant`, `.{...}`, branch, or multi-assignment
  RHS expressions before the correct LHS diagnostic.
- Root shadow checks used the process-global global-name table. A global in an
  unrelated, non-visible module could incorrectly turn a visible namespace
  alias into a value root for both single and multi stores.

Add direct/nested optional, enum, struct, branch, and multi-store regressions
and classify every qualified lvalue into a complete source-aware verdict before
lowering any RHS. Invalid verdicts must diagnose the target first and must not
leak an unrelated target type into the RHS.
