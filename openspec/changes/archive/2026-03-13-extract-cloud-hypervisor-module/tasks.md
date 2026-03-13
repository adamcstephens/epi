## 1. Create cloud_hypervisor module

- [x] 1.1 Create `src/cloud_hypervisor.rs` with binary name constants for `cloud-hypervisor` and `ch-remote`
- [x] 1.2 Add `mod cloud_hypervisor` to `src/lib.rs`

## 2. Move CH argument building

- [x] 2.1 Add `build_args()` function to the module that takes structured inputs (descriptor fields, disk path, seed ISO, serial socket, passt socket, virtiofsd sockets, API socket path) and returns `Vec<String>` of CH CLI arguments
- [x] 2.2 Replace inline CH arg construction in `vm_launch.rs` (lines 139–179) with a call to `cloud_hypervisor::build_args()`

## 3. Add ExecStop and systemd property generation

- [x] 3.1 Add `service_properties()` function that takes API socket path, helper unit names, and returns `Vec<String>` of systemd properties (ExecStop sequence, ExecStopPost for helpers, After ordering, TimeoutStopSec)
- [x] 3.2 Update `vm_launch.rs` to call `cloud_hypervisor::service_properties()` instead of building ExecStopPost inline

## 4. Update process::run_service

- [x] 4.1 Change `run_service` to accept `properties: &[String]` instead of `exec_stop_posts: &[&str]`, since the caller now provides all extra properties
- [x] 4.2 Update the call site in `vm_launch.rs`

## 5. Test

- [x] 5.1 Run `just test` to verify unit and CLI tests pass
- [x] 5.2 Launch a VM with e2e_lifecycle test and verify it works identically
