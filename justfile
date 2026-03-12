default:
    just --list

format:
    ocamlformat --inplace **/*.ml **/*.mli
    nixfmt **/*.nix

run *args:
    dune exec -- epi {{ args }}

test-unit:
    dune exec test/unit/test_unit.exe

test-cli:
    dune exec test/test_epi.exe -- _build/default/bin/epi.exe

test-e2e *args:
    dune exec test/e2e/test_e2e.exe -- test {{ args }} -e
