# 0252 — value-spread polish: generic-dispatch gap, double diagnostic, struct-spread message

> **RESOLVED (2026-07-10).** Generic calls expand name-shaped tuple/array spreads before type binding; unsupported pack spreads stop after the primary diagnostic; fixed-arity struct spreads already use the dedicated cannot-spread diagnostic.

Three non-blocking gaps left by the issue-0156p2 landing (its review
verdict: SAFE with optional folds — all three are cleanly diagnosed
today, none crash):

1. **Value spread into a generic (`$T`) fn unsupported.**
   `pair :: (a: $T, b: $T) -> $T => a + b;  p := .(40, 2);  pair(..p)`
   → "unresolved 'spread_expr'". The early generic-dispatch branch in
   `lowerCall` (src/ir/lower/call.zig ~392-408) lowers args with
   lowerExpr and never routes spreads through the value-spread
   expansion before lowerGenericCall. Expected: 42.

2. **Tuple spread of a CALL operand into a PACK fn double-diagnoses.**
   `print("{} {}\n", ..make_pair())` → the correct "unresolved
   'spread_expr'" PLUS a spurious "pack index 1 out of bounds" from
   fmt.sx. `spreadElemNodes` (pack.zig) deliberately expands only
   name-shaped operands (single-eval discipline — correct); the
   fall-through needs to suppress the secondary pack-arity error.
   (Note: the fixed-arity path `add2(..make_pair())` works and
   single-evals — only the pack-fn path needs the operand hoisted into
   a temp, or the cleaner diagnostic.)

3. **Struct spread into a fixed-arity fn reports arity, not "cannot
   spread".** `add2(..structval)` → "'add2' expects 2 arguments, but 1
   was given" instead of the located "cannot spread a value of type
   'S'". The Ref.none placeholder survives to the arity check on this
   shape. (The issue-0188 fold added rejectLeftoverSpreadPlaceholder —
   verify whether it already covers this; if yes, only 1 and 2 remain.)

## Investigation prompt

All three sit in the spread machinery the 0156p2 + 0188-fold landings
built (src/ir/lower/call.zig arg loop + early generic branch,
src/ir/lower/pack.zig spreadElemNodes/packVariadicCallArgs). For (1),
run the value-spread expansion before the generic-dispatch arg
lowering (mind inference: the expanded element types drive $T).
For (2), either hoist a non-name-shaped operand into a synthetic temp
binding (single eval) and expand from that, or detect the
already-diagnosed spread and skip the pack-arity check. For (3), route
the placeholder rejection before checkCallArity for EVERY callee kind.
Extend examples/packs/0830 (positive, case 1) and diagnostics/1214
(cases 2-3). Corpus green.

From the 0156p2 adversarial review (2026-07-04).
