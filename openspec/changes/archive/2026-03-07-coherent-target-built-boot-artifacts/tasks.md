## 1. Descriptor and Validation Changes

- [x] 1.1 Update target descriptor handling so NixOS launch artifacts are treated as one coherent kernel/initrd/disk set.
- [x] 1.2 Add pre-launch coherence validation in VM provisioning and return actionable errors when artifacts are mixed or incompatible.
- [x] 1.3 Ensure cloud-hypervisor launch is skipped when coherence validation fails.

## 2. Manual-Test Target Alignment

- [x] 2.1 Update `manual-test` NixOS target wiring to provide disk artifacts from target-built outputs instead of a mutable workspace image.
- [x] 2.2 Update manual-testing documentation to describe coherent target-built artifact expectations for `epi up --target .#manual-test`.

## 3. Verification

- [x] 3.1 Run unit/integration tests that cover descriptor validation and `epi up` failure paths.
- [x] 3.2 Manually validate `dune exec epi -- up --target .#manual-test --console` boots without stage1->stage2 handoff failure.
- [x] 3.3 Confirm error messaging points users to fixing target outputs when coherence checks fail.
