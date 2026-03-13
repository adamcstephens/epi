## 1. Enable API socket in cloud-hypervisor launch

- [x] 1.1 Add `api.sock` path construction and stale socket cleanup in `launch_vm_inner`
- [x] 1.2 Pass the API socket path to `cloud_hypervisor::build_args()`

## 2. Configure ExecStop graceful shutdown sequence

- [x] 2.1 Update `cloud_hypervisor::service_properties()` to build ExecStop sequence when API socket is provided: `ch-remote power-button`, `timeout 15 tail --pid=$MAINPID -f /dev/null`, `ch-remote shutdown-vmm`
- [x] 2.2 Change `TimeoutStopSec` to 20 (4s buffer over the 15s wait)
- [x] 2.3 Add `After=<helper>.service` ordering for each helper unit in `service_properties()`
- [x] 2.4 Pass the API socket path to `cloud_hypervisor::service_properties()` in `vm_launch.rs`

## 3. Test

- [x] 3.1 Run `just test` to verify unit and CLI tests pass
- [x] 3.2 Run e2e_lifecycle test to verify VMs still launch and stop correctly
- [x] 3.3 Add e2e test that verifies graceful shutdown completes within expected time
