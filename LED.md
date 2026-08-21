# Status LED layer (local branch)

This branch adds a third blackout layer to Umbra: the Mac's status LED goes dark
along with the screens, and comes back with them.

It lives on a local branch rather than in `main` because it needs root, and a
feature that installs a sudoers rule does not belong in something people clone
and run without reading.

## Why the LED matters here

Umbra exists so a Mac being used remotely does not display its desktop to the
room. A lit status LED undoes a good part of that: the machine still visibly
announces that it is awake and in use.

## How the LED is switched

Through the SMC. Enumerating the key table on a Mac mini M2 (Mac14,3) gives the
three keys involved and, importantly, their attribute bytes:

| Key | Type | Attr | Meaning |
|---|---|---|---|
| `LSOF` | flag | `0x80` | read-only — the override status |
| `LSOO` | flag | `0x50` | write + function — the command, **not readable by design** |
| `LSRB` | flag | `0x50` | write + function — hands the LED back to the firmware |

`0x80` is the Read bit; `0x50` is Write | Function. So `LSOO` cannot be read
back, and the helper writes `LSOO` then reads `LSOF` to confirm. That looks like
a mistake until you see the attributes — it is the only thing that can work.

Writing `LSOO = 0` turns the LED off, `1` turns it on.

## What the sudoers rule actually grants

`Tools/install-led-helper.sh` installs two files:

```
/usr/local/libexec/umbra-led     root:wheel 0755, NOT setuid
/etc/sudoers.d/umbra-led         root:wheel 0440
```

The rule permits one user to run one binary as root with one of four fixed
arguments, and nothing else:

```
<user> ALL=(root) NOPASSWD: /usr/local/libexec/umbra-led status,
                            /usr/local/libexec/umbra-led off,
                            /usr/local/libexec/umbra-led on,
                            /usr/local/libexec/umbra-led revert
```

The helper takes **no SMC key names from its caller** — all three keys are
compiled in, and any argument that is not one of the four commands exits 64
without opening the SMC connection. The grant cannot be widened by passing
something clever.

The installer syntax-checks the rule with `visudo -cf` before it is ever placed
in `sudoers.d`, because a malformed file there can lock you out of `sudo`
entirely.

Deliberately **not setuid**: a setuid root binary is a standing local-privilege
surface, where any parsing bug becomes a root bug. A sudoers rule is auditable,
scoped, and revoked by deleting one file.

## Install

```bash
./Tools/install-led-helper.sh          # asks for your password once
./Tools/install-led-helper.sh --uninstall
```

Then relaunch Umbra. The LED row appears under **Darkness** in the menu, and
`--selftest` reports the helper and the current LED state.

## Caveats

The SMC firmware still owns the LED. It reclaims it across sleep, reboot, and
the power button, so an override does not survive those. Umbra reasserts it on
`NSWorkspace.didWakeNotification` when the screens are still meant to be dark.

On quit, Umbra switches the LED back on and then sends `LSRB`, so it stops
overriding rather than merely setting a value — the machine is left as found.

Everything here is specific to Macs that expose these keys. On a Mac that does
not, the helper's `status` fails, the layer reports itself unavailable, and the
rest of Umbra is unaffected.
