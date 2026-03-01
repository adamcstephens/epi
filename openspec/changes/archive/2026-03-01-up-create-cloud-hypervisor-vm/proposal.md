## Why

The `epi up` command currently records an instance-to-target mapping but does not actually provision or start a VM. This makes the command behavior misleading and blocks the intended local VM workflow from a Nix flake target.

## What Changes

- Make `epi up` provision and start a cloud-hypervisor VM for the selected instance using the provided `--target <flake-ref>#<config-name>`.
- Resolve the target into concrete runtime inputs needed to launch the VM (for example kernel, initrd/rootfs, and VM runtime config) through the existing Nix target contract.
- Persist instance metadata only after successful VM creation so state reflects real running/provisioned instances.
- Return actionable errors when target evaluation or VM creation fails.
- Keep existing instance-name behavior (`default` fallback and named instances).
- Launch VM processes in detached mode so `epi up` returns after successful start.
- Add a serial console access path that can attach on demand to a running VM.
- Track runtime process metadata (PID and launch lock ownership context) and reconcile it quickly during CLI startup.

## Capabilities

### New Capabilities
- `vm-provision-from-target`: Provision and boot an instance VM via cloud-hypervisor from a Nix flake target, with clear success/error semantics in `epi up`.
- `vm-detached-serial-console`: Keep provisioned VMs running in the background while exposing a serial console attach workflow.
- `vm-runtime-state-reconciliation`: Reconcile tracked VM runtime metadata (PID and lock context) at CLI startup and surface lock conflicts with actionable guidance.

### Modified Capabilities
- None.

## Impact

- Affected code: CLI `up` flow in `lib/epi.ml`, plus new VM provisioning/invocation logic and process orchestration.
- Affected runtime dependencies: cloud-hypervisor invocation path and target-evaluation tooling used by `up`.
- Affected tests: `up` command tests must be updated to validate provisioning behavior, success output, and failure handling (likely with stubs/mocks for external process calls).
