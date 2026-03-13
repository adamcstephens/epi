## 1. Replace stdin reading

- [x] 1.1 Set stdin fd to non-blocking using `nix::fcntl` with `O_NONBLOCK`
- [x] 1.2 Replace `event::poll`/`event::read` loop with raw `stdin.read()` into a byte buffer
- [x] 1.3 Implement byte-level Ctrl-T + q/Q detach detection with `ctrl_t_pending` state across reads
- [x] 1.4 Forward non-detach bytes directly to the serial socket

## 2. Cleanup

- [x] 2.1 Remove `key_to_bytes` function
- [x] 2.2 Remove unused crossterm `event` imports (`Event`, `KeyCode`, `KeyEvent`, `KeyModifiers`)

## 3. Testing

- [x] 3.1 Run `just test` to verify existing tests pass
- [ ] 3.2 Manual test: attach to a VM console and verify arrow keys, Home, End, Tab, Ctrl-C all work
