### Requirement: NixOS module exposes hook options for each hook point
The NixOS module SHALL expose `epi.hooks.guest-init`, `epi.hooks.post-launch`, and `epi.hooks.pre-stop` options, each typed as `attrsOf path` with a default of `{}`. Keys are script names (used for lexical ordering), values are paths to executable scripts (typically Nix store paths).

#### Scenario: Declaring a guest-init hook in NixOS config
- **WHEN** a user sets `epi.hooks.guest-init."seed-db.sh" = pkgs.writeShellScript "seed-db" "mix ecto.migrate";`
- **THEN** the NixOS module accepts the configuration without errors

#### Scenario: Declaring a post-launch hook in NixOS config
- **WHEN** a user sets `epi.hooks.post-launch."setup.sh" = lib.getExe pkgs.somePackage;`
- **THEN** the NixOS module accepts the configuration without errors

#### Scenario: No hooks declared by default
- **WHEN** a user does not set any `epi.hooks.*` options
- **THEN** the default is empty attrsets and no hooks are added

### Requirement: Host hook paths are included in the target descriptor
The NixOS module SHALL include `epi.hooks.post-launch` and `epi.hooks.pre-stop` hook paths in the target descriptor output, sorted lexically by key name. The target descriptor SHALL include a `hooks` field with `post-launch` and `pre-stop` arrays containing the sorted paths. Empty hook sets SHALL be omitted from the descriptor.

#### Scenario: Post-launch hooks appear in target descriptor
- **WHEN** `epi.hooks.post-launch` contains `{ "00-setup.sh" = /nix/store/...-setup; "01-check.sh" = /nix/store/...-check; }`
- **THEN** the target descriptor `hooks.post-launch` array is `["/nix/store/...-setup", "/nix/store/...-check"]` (sorted by key)

#### Scenario: No host hooks yields no hooks field
- **WHEN** both `epi.hooks.post-launch` and `epi.hooks.pre-stop` are empty
- **THEN** the target descriptor does not contain a `hooks` field

### Requirement: Guest-init hooks are baked into the epi-init service
The NixOS module SHALL embed `epi.hooks.guest-init` hook paths into the `epi-init` service script, sorted lexically by key name. These hooks SHALL execute after file-based guest hooks from the seed ISO, using the same `su - <username> -c <script>` mechanism. Each hook failure SHALL be logged but SHALL NOT prevent remaining hooks from executing.

#### Scenario: Nix guest-init hooks run after seed ISO hooks
- **WHEN** the seed ISO contains file-based guest hooks
- **AND** `epi.hooks.guest-init` declares additional hooks
- **THEN** file-based hooks execute first, then Nix-declared hooks execute in lexical key order

#### Scenario: Nix guest-init hook failure is logged but non-blocking
- **WHEN** a Nix-declared guest-init hook exits with code 1
- **THEN** the failure is logged
- **AND** remaining hooks continue executing
- **AND** the VM continues booting
