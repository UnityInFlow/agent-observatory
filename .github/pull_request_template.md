## What this changes

<!-- One paragraph. What is different after this merges. -->

## Why

<!-- The problem, not the solution. Link the issue if there is one. -->

## Verification

<!-- Paste real output. A green CI run is evidence; "tests pass" is a claim. -->

```
make test-runner     →
make test-web        →
make test-api        →
```

## Measurement integrity

Tick only what you checked. Delete anything that does not apply.

- [ ] No change to how a metric is computed, or the change is stated explicitly and every
      past result that used the old computation is identified
- [ ] Unknown data still reads as unknown — no gap defaulted into a plausible number
- [ ] If this touches the analyzer: the §13.1 gate still decides before efficiency is
      compared, and arm-completeness still fails closed
- [ ] If this adds a field to a run record: it is representable, not merely documented.
      A schema note constrains nothing until something executes and rejects the bad value

## Anything a reviewer should disbelieve

<!-- Where you are least sure. Say which number you would be least surprised to find wrong. -->
