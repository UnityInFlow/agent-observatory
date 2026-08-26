---
name: Data integrity
about: A recorded value is fabricated, unrepresentable, or unvalidated
title: "[DATA] "
labels: data-integrity
---

## The value

<!-- Which field, in which artifact. Give the file and line. -->

## What is wrong with it

- [ ] Fabricated — a gap is stored as a real value (a default that reads as a measurement)
- [ ] Unrepresentable — the true value has nowhere to go in the schema
- [ ] Unvalidated — nothing executes to reject a wrong value
- [ ] Inferred — downstream code guesses the fact from a value pattern instead of reading it

## Evidence

<!-- A query, a row count, a file:line. How many existing records are affected? -->

## Does a live result depend on it?

<!-- Answer directly. "No live result depends on this" is a valid and useful answer, and it
     changes the urgency completely. -->

## Fix order

<!-- Make it representable before tightening validation: tightening first rejects records
     for fields that do not exist yet. -->
