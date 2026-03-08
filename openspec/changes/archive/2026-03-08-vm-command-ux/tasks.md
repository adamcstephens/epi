## 1. Rename Commands

- [x] 1.1 Rename `up_command` binding to `launch_command` in `lib/epi.ml`
- [x] 1.2 Update the registration from `("up", up_command)` to `("launch", launch_command)` in the command group
- [x] 1.3 Rename `down_command` binding to `stop_command` in `lib/epi.ml`
- [x] 1.4 Update the registration from `("down", down_command)` to `("stop", stop_command)` in the command group

## 2. Update Error Messages and Help Text

- [x] 2.1 Update `~summary` and `~readme` in `launch_command` to reference `epi launch`
- [x] 2.2 Update `~summary` and `~readme` in `stop_command` to reference `epi stop`
- [x] 2.3 Update `resolve_instance_target` error messages: replace `epi up` with `epi launch`
- [x] 2.4 Update `ssh_command` error messages: replace `epi up` with `epi launch`
- [x] 2.5 Update the top-level `cmd` readme/examples to use `launch` and `stop`

## 3. Implement start Command

- [x] 3.1 Add `start_command` in `lib/epi.ml`: accepts optional positional instance name, looks up stored instance in store (fails with guidance if missing), and relaunches using stored target
- [x] 3.2 Handle already-running case: print notice and exit zero
- [x] 3.3 Handle stale runtime case: clean up stale PIDs (passt, virtiofsd) then provision
- [x] 3.4 Support `--console` flag on `start_command` for post-start console attachment
- [x] 3.5 Register `("start", start_command)` in the command group

## 4. Test

- [x] 4.1 Run `dune exec epi -- launch --help` and verify help text references `launch`
- [x] 4.2 Run `dune exec epi -- stop --help` and verify help text references `stop`
- [x] 4.3 Run `dune exec epi -- start --help` and verify help text is correct
- [x] 4.4 Run `dune exec epi -- list` to confirm CLI builds and runs
- [x] 4.5 Run the test suite with `dune test` and fix any failures from renamed commands
