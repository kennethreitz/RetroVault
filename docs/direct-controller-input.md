# Reading a Switch 2 Pro Controller directly

**Status:** proven working against hardware on 29 July 2026, then rolled back.
The implementation is not in the tree. It is in `git stash`, labelled
`Switch2 direct input driver (rolled back 2026-07-29)`.

```sh
git stash list                       # find it
git stash show -p 'stash@{n}'        # read it without restoring
git stash pop 'stash@{n}'            # bring it back
```

A stash is not a safe archive — `git stash clear`, or popping and discarding,
loses it. If this is picked up again, get it onto a branch early. This note
exists so the three findings below survive even if the code does not.

## What it did

RetroVault read a wired controller itself, with no Switch2Bridge process and no
DSU/UDP hop. The driver produced a `DSUPadState` and conformed to
`DSUPadReading`, so it dropped in as an alternative `padSource` and every
consumer downstream — button mapping, port routing, the exit chord, sensors —
needed no changes at all.

Measured on a real Pro Controller: init sequence acknowledged 4/4, then **501
input reports in 2 seconds — 250 Hz**, from inside the App Sandbox. Against
33 Hz over Bluetooth and one process plus a UDP hop for wired DSU.

Bluetooth was deliberately out of scope. Reaching the controller over BLE means
reimplementing the CoreBluetooth client that *is* Switch2Bridge, and the
controller's 30 ms connection interval on macOS dwarfs anything the transport
below it could save.

## The three things that cost time

### 1. IOKit property matching must be nested under `IOPropertyMatch`

This is the one that made the driver silently do nothing.

```swift
// WRONG — the constraints are ignored, and the match finds nothing.
let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
matching["idVendor"] = 0x057E
matching["idProduct"] = 0x2069
matching["bInterfaceNumber"] = 1

// RIGHT
matching[kIOPropertyMatchKey] = [
    "idVendor": 0x057E, "idProduct": 0x2069, "bInterfaceNumber": 1,
] as NSDictionary
```

Top-level keys other than IOKit's own matching keys are not an error. They are
ignored, so this fails by finding nothing rather than by complaining. The
interface was in the registry the whole time — confirm with:

```sh
ioreg -c IOUSBHostInterface -r -l | grep -E '"idVendor"|"bInterfaceNumber"|"bInterfaceClass"'
```

`idVendor = 1406` (0x057E), `idProduct = 8297` (0x2069), and interface 1 carries
`bInterfaceClass = 255`, the vendor class that takes the init sequence.

### 2. The sandbox needs *two* entitlements, not one

`com.apple.security.device.usb` alone is not enough, and the failure is split:

| Operation | `device.usb` only | plus the exception |
|---|---|---|
| `IOHIDManagerOpen` | `0` success | `0` success |
| `IOUSBHostInterface(...)` | `kIOReturnInternalError`, "Failed [super init]" | success |

Both are needed:

```xml
<key>com.apple.security.device.usb</key>
<true/>
<key>com.apple.security.temporary-exception.iokit-user-client-class</key>
<array>
    <string>AppleUSBHostFrameworkInterfaceClient</string>
</array>
```

That one user-client class is sufficient; `IOUSBHostInterfaceUserClient` and
`IOUSBHostDeviceUserClient` were tried alongside it and are not required.

Worth being precise about, because it is easy to confuse with a different wall:
this is **not** `com.apple.developer.hid.virtual.device`. That one is
Apple-restricted, needs an organization account and per-request approval, and
ad-hoc signing it gets the process SIGKILLed by AMFI. It would be needed to
*create* a virtual gamepad so macOS games see the controller system-wide. It is
not needed to *read* a real device, which is all this does.

A sandbox entitlement is only enforced on a signed bundle. A bare command-line
binary signed with `com.apple.security.app-sandbox` is killed at launch with
SIGTRAP because it has no container — test with a real `.app`.

### 3. IOKit's input report buffer includes the report ID

`IOHIDDeviceRegisterInputReportCallback` hands over a buffer whose byte 0 is the
report ID, with `reportLength` counting it. A live capture:

```
09 c2 20 00 00 00 b8 27 86 6b b8 84
^^ report id   ^^ buttons start here
   ^^ body byte 0: the counter
```

So the body — the payload the Bluetooth path carries, and what the existing
parser expects — starts at **byte 1**. Reading from byte 0 shifts every field by
one: buttons pick up the counter and read a permanent phantom press, and the
sticks decode from button bytes. The symptom is input "jumping all over the
place" while otherwise working.

Switch2Bridge's own `docs/PROTOCOL.md` already recorded this — *"USB just
prepends the HID report ID"* — which would have saved the round trip.

Decoded correctly, an untouched controller reads `buttons 00 00 00` with all
four axes near 2048 (`L(1976,2138) R(2165,2124)`), stable to ±1.

## Still unresolved

- **Two processes cannot share the controller.** Switch2Bridge and RetroVault
  both claim vendor interface 1, and whichever starts second fails. There is no
  arbitration; the user has to run one or the other. Useful diagnostic: if a
  known-good external probe suddenly cannot open the interface, something else
  already holds it.
- **The driver's `os_log` output was never visible.** `log show --predicate
  'subsystem == "org.kennethreitz.RetroVault"'` returned zero lines across the
  whole session, for existing categories as well as new ones. Every diagnosis
  here came from a standalone signed probe binary instead. That logging gap is
  worth fixing on its own account, independent of controller work.
