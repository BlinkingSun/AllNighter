# AllNighter — control reference for scripts & local agents

AllNighter is a macOS menu-bar app that prevents the Mac from sleeping. It exposes
a small HTTP API bound to **127.0.0.1 only** (loopback, not reachable from the
network) so a local script or AI agent can read and change the state without UI
clicks.

## Two modes

1. **Display keep-awake** — `caffeinate -d -i`; blocks display + idle system
   sleep. Screen stays on. Lid-close still sleeps.
2. **Closed-lid keep-alive** — `pmset -a disablesleep 1`; the Mac stays awake with
   the lid closed (screen may turn off). Needs root: first enable prompts once and
   installs a `visudo`-validated NOPASSWD rule allowing only
   `pmset -a disablesleep 0|1`; silent thereafter. Reverts to `0` on toggle-off,
   quit, and SIGTERM/SIGINT.

## Endpoints

Base URL: `http://127.0.0.1:17893`

| Method | Path | Effect | Response |
|--------|------|--------|----------|
| GET | `/status` | Read both modes | `{"state":"on\|off","closedLid":"on\|off"}` |
| POST | `/on` `/off` `/toggle` | Display keep-awake | `{"state":"on\|off"}` |
| POST | `/lid/on` `/lid/off` `/lid/toggle` | Closed-lid keep-alive | `{"closedLid":"on\|off"}` |

`GET` also works on the mutating routes.

```bash
curl -s http://127.0.0.1:17893/status
curl -s -X POST http://127.0.0.1:17893/on
curl -s -X POST http://127.0.0.1:17893/lid/on
```

## Notes for agents

- Confirm state with `GET /status` before and after a change.
- Enabling closed-lid mode may trigger a one-time GUI admin prompt; if no human is
  present to answer it, the enable is a no-op (state stays off).
- The menu-bar pill turns green when display keep-awake is on and gains a yellow
  ring when closed-lid keep-alive is on.
