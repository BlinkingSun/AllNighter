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
| GET | `/status` | Read all modes | `{"state":"on\|off","closedLid":"on\|off","agent":"on\|off","agentIds":N,"effectiveDisplay":"on\|off","effectiveLid":"on\|off"}` |
| POST | `/on` `/off` `/toggle` | Display keep-awake (USER switch) | `{"state":"on\|off"}` |
| POST | `/lid/on` `/lid/off` `/lid/toggle` | Closed-lid keep-alive (USER switch) | `{"closedLid":"on\|off"}` |
| POST | `/agent/on?id=X` | Hold the AGENT switch (adds `X` to holder set) | `{"agent":"on","ids":N}` |
| POST | `/agent/off?id=X` | Release holder `X` (unknown id = no-op) | `{"agent":"on\|off","ids":N}` |
| POST | `/agent/clear` | Release all holders | `{"agent":"off","ids":0}` |
| GET | `/agent/status` | Inspect holders | `{"agent":"on\|off","ids":N,"idList":[...]}` |

`GET` also works on the mutating routes.

## The agent switch (use this one if you are an agent)

- While held, the Mac stays awake **with the lid closed** regardless of the user
  switches: `effectiveDisplay = user on OR agent on`, `effectiveLid = user lid on
  OR agent on`. Releasing it never overrides a user switch that is on.
- Hold it with your own stable `id` (session id) when you start working; release
  the same id when you finish. Ids form a set — duplicates collapse, other agents'
  holds are unaffected, and the switch releases when the set empties.
- It is **sticky** (no timeout) and in-memory (app relaunch clears it). If you may
  have crashed without releasing, `POST /agent/clear` or the menu's *Clear agent
  keep-awake* recovers.
- The user routes (`/on`, `/off`, `/lid/*`) belong to the human. Only use them
  when the user explicitly asks for keep-awake.
- Agent routes never trigger an admin prompt. If closed-lid can't be applied yet
  (sudoers rule not installed), `effectiveLid` reports desired state; `pmset -g`
  is hardware truth.
- While any agent holds the switch the pill pulses with a gold ring (the user
  sees you are keeping the Mac awake); the pill itself still shows the user
  display switch.

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
