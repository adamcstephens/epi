## 1. CLI wiring

- [x] 1.1 Add the `vm rm` entry point to the VM CLI command table and parse positional ID plus optional flags
- [x] 1.2 Route `vm rm` into the VM lifecycle module with clear validation of the provided VM identifier

## 2. Force handling

- [x] 2.1 Honor the `-f/--force` flag by triggering the termination flow before attempting deletion and waiting for completion
- [x] 2.2 Fail fast when force termination does not succeed, returning a descriptive error while leaving the VM untouched

## 3. Verification & docs

- [x] 3.1 Add automated tests covering stopped deletion, forced deletion, rejection without force, and termination failures
- [x] 3.2 Document `vm rm` and the `--force` behavior in the CLI reference
