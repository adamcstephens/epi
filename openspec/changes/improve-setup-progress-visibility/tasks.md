## 1. Define Progress Stage Contract

- [ ] 1.1 Identify the `epi up` orchestration boundaries for target evaluation/build, launch preparation, and VM launch.
- [ ] 1.2 Define stable user-facing stage message text for start/transition/completion events and align with existing CLI tone.

## 2. Implement Stage Visibility in Up Flow

- [ ] 2.1 Add progress message emission at the selected stage boundaries in the `epi up` execution path.
- [ ] 2.2 Ensure progress emission is best-effort and does not alter provisioning state persistence or error propagation.

## 3. Validate Behavior and Output

- [ ] 3.1 Add or update tests to assert stage visibility for long-running target evaluation/build and launch flow.
- [ ] 3.2 Verify existing success/failure output remains actionable and includes stage context when failures occur.

## 4. Manual Verification

- [ ] 4.1 Run `dune exec epi -- up --target .#manual-test` and confirm visible stage transitions during setup.
- [ ] 4.2 Confirm output remains concise (major steps only) and does not require verbose mode.
