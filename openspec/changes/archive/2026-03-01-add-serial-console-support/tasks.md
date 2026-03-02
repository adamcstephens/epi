## 1. Add native serial relay support

- [x] 1.1 Add socket relay helpers for stdin/stdout forwarding
- [x] 1.2 Implement serial socket connection with bounded retry for startup races
- [x] 1.3 Add actionable serial endpoint errors for unavailable sockets

## 2. Update console command implementation

- [x] 2.1 Refactor `console_command` in `lib/epi.ml` to call `Vm_launch.attach_console`
- [x] 2.2 Route console attach through native socket relay path
- [x] 2.3 Add serial socket existence validation
- [x] 2.4 Implement `Vm_launch.attach_console` as native socket relay

## 3. Add up --console flag

- [x] 3.1 Add `--console` flag to `up_command` argument parser
- [x] 3.2 Update `up_command` logic to check `--console` flag after provisioning
- [x] 3.3 Handle case where instance is already running (skip provisioning, attach directly)
- [x] 3.4 Ensure VM is actually running before console attachment when using `--console`

## 4. Testing and validation

- [x] 4.1 Test `epi console` with running instance
- [x] 4.2 Test `epi console` with non-running instance (error case)
- [x] 4.3 Test `epi up --console` with fresh VM
- [x] 4.4 Test `epi up --console` with already running VM
- [x] 4.5 Test `up --console` attach behavior when socket appears shortly after launch
- [x] 4.6 Test error when serial socket is missing
