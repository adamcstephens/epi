## Purpose
Define how `epi up` sizes the writable disk overlay so VMs have enough root-filesystem space for typical development use.

## Requirements

### Requirement: epi up accepts --disk-size to control overlay disk size

The `epi up` command SHALL accept an optional `--disk-size <size>` flag that specifies the target size of the writable disk overlay (e.g. `40G`, `50G`). When omitted, the CLI SHALL use a built-in default of `40G`. The flag SHALL only apply when a new overlay is being created; if an overlay already exists for the instance, `--disk-size` is ignored.

#### Scenario: Overlay created with default size

- **WHEN** user runs `epi up --target .#config` and no overlay exists for the instance
- **THEN** the CLI creates a writable overlay and resizes it to 40 GiB
- **AND** the VM boots with a 40 GiB disk

#### Scenario: Overlay created with explicit --disk-size

- **WHEN** user runs `epi up --target .#config --disk-size 50G` and no overlay exists for the instance
- **THEN** the CLI creates a writable overlay and resizes it to 50 GiB
- **AND** the VM boots with a 50 GiB disk

#### Scenario: --disk-size ignored when overlay already exists

- **WHEN** user runs `epi up --target .#config --disk-size 50G` and an overlay already exists for the instance
- **THEN** the CLI uses the existing overlay unchanged
- **AND** no resize is performed

### Requirement: epi up resizes the overlay using qemu-img

After copying the Nix-store disk image to the instance overlay path, the CLI SHALL invoke `qemu-img resize <overlay-path> <size>` to enlarge the file to the requested size. The CLI SHALL locate `qemu-img` via the `EPI_QEMU_IMG_BIN` environment variable if set, falling back to `qemu-img` on `$PATH`.

#### Scenario: qemu-img resizes the overlay

- **WHEN** a new overlay is created during `epi up`
- **THEN** `qemu-img resize` is invoked with the overlay path and the target size
- **AND** `epi up` proceeds to launch the VM after a successful resize

#### Scenario: qemu-img not found

- **WHEN** `--disk-size` resize is needed but `qemu-img` is not on `$PATH` and `EPI_QEMU_IMG_BIN` is not set
- **THEN** `epi up` exits non-zero
- **AND** the error states that `qemu-img` was not found
- **AND** the error suggests installing `qemu-utils` or setting `EPI_QEMU_IMG_BIN`

#### Scenario: qemu-img resize fails

- **WHEN** `qemu-img resize` exits non-zero (e.g. requested size is smaller than image)
- **THEN** `epi up` exits non-zero
- **AND** the error identifies the resize failure stage and includes the `qemu-img` exit details
