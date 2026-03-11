## 1. Update list command

- [x] 1.1 Modify `list` in `lib/epi.ml` to check runtime state and liveness for each instance, outputting four columns: INSTANCE, TARGET, STATUS, SSH
- [x] 1.2 Update list-related test expectations to match new four-column output format

## 2. Update status command

- [x] 2.1 Modify `status` in `lib/epi.ml` to output labeled fields (Instance, Target, Status) and conditionally show runtime details (SSH port, serial socket, disk, unit ID) when running
- [x] 2.2 Update status-related test expectations to match new output format

## 3. Verify

- [x] 3.1 Run full test suite (`dune test`) and fix any failures
- [x] 3.2 Manual test with a real VM: `epi list` and `epi status` show correct running/stopped state
