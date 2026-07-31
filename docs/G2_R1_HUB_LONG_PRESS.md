# G2/R1 long press while an EvenHub page is active

Status: hardware-verified on 2026-07-25 with a physical G2 pair
and an R1 ring. No firmware was modified.

## Conclusion

A true R1 long-press down/up stream and an active EvenHub page are not
available together through the interfaces currently exposed by the tested G2
firmware.

- In Daily/Hub mode, an EvenHub app receives single press, double press, swipe
  up, and swipe down. A one-second hold is consumed by G2 as the global Menu
  shortcut.
- In Terminal mode, the private Terminal service provides real hold start and
  stop messages, but Terminal replaces the EvenHub foreground surface.
- A phone connection directly to the R1 management GATT service did not
  receive TouchPad gesture notifications on the tested firmware. The R1
  continued to use its separate controller link to G2.

This is an event-routing boundary, not a Flutter or Android BLE problem.
Keeping two phone apps open, opening a second GATT connection, or changing the
EvenHub event-capture container cannot add an event that the firmware does not
publish.

## Evidence

### Public EvenHub contract

The current [EvenHub Device APIs documentation][device-apis] lists exactly
four touch events for both G2 and R1:

| Event | Value |
| --- | ---: |
| `CLICK_EVENT` | 0 |
| `SCROLL_TOP_EVENT` | 1 |
| `SCROLL_BOTTOM_EVENT` | 2 |
| `DOUBLE_CLICK_EVENT` | 3 |

There is no public long-press event. `isEventCapture` selects the text or list
container that receives those events; it is not a gesture subscription mask.

Even's [Menu documentation][menu] separately specifies that a one-second hold
on either the glasses or R1 opens the global Menu from any interface. These
contracts explain the observed Daily/Hub behavior.

### Physical Terminal trace

After selecting `MODE_TERMINAL`, advertising a connected host/session, and
putting the agent in `AGENT_AWAIT_USER`, the same R1 hold produced:

```text
hold down: 08 A2 01 10 0B 52 02 08 01
hold up:   08 A2 01 10 0E 52 02 08 02
```

They decode as Terminal command `0xA2`, respectively
`long_press_start` and `long_press_stop_manual`. Raw microphone notifications
then arrived from the left lens as 205-byte BLE values containing five
40-byte LC3 frames.

This proves that the R1 hardware and its R1-to-G2 controller link support the
hold. The missing part is routing that hold to an EvenHub page.

### Daily/Hub trace

In Daily/Hub mode, ordinary R1 gestures arrive through EvenHub with R1 source
`2`. On a hold, firmware may emit an R1 activity marker and page lifecycle
events such as `foreground_exit`/`system_exit`, then opens its Menu. It does
not emit a typed hold-down or hold-up event.

The lifecycle sequence is useful evidence that a hold probably occurred, but
it is not equivalent to the Terminal event:

- another native foreground takeover can look similar;
- the native Menu can appear before the app reacts;
- release timing is unavailable;
- recreating the Hub page does not reliably dismiss a separate system overlay.

## Non-firmware approaches

### 1. Keep audio continuous and use typed Hub gestures

Remain in Daily/Hub mode and use tap, double press, and swipe only for
application interaction. These events work with the normal Hub page, are
attributable to G2 or R1, and do not depend on timing heuristics.

The current POC keeps microphone streaming active, treats tap as a display-only
event, and uses double-tap for application interaction. Outside memo mode,
double-tap requests a read-only progress update from the last agent that
successfully received a WebSocket command. During memo mode it finishes the
memo. Raw BLE audio is logged as LC3. The public EvenHub SDK performs host-side
conversion and exposes 16 kHz mono PCM, as shown in Even's
[Device APIs audio section][device-apis-audio] and official
[ASR template][asr-template].

### 2. Infer a hold from Menu takeover (experimental)

The POC can correlate an R1 source marker with an immediate Hub lifecycle exit,
or treat an otherwise untyped foreground takeover as an inferred hold. It
labels the event `inferred_long_press`, attempts to recreate the Hub page, and
reasserts continuous LC3 audio.

This may be useful for a prototype, but it must not be treated as a real
hold-to-talk down/up contract.

### 3. Use Terminal for true hold-to-talk

Terminal mode is reliable for `long_press_start` and
`long_press_stop_manual`, and it streams microphone data. It is a runtime
operating-mode switch and does not flash or modify firmware. Its tradeoff is
that the Terminal UI owns the foreground instead of the Hub page.

The protocol implementation remains available for diagnostics, but the
soft-kiosk visualizer locks the active profile to Daily/Hub mode because
Terminal and Hub cannot own the foreground together.

## Approaches ruled out on the tested hardware

- **A second Android app/GATT client:** BLE characteristics do not broadcast
  exclusive controller input to arbitrary clients. Competing clients can also
  cause ownership, subscription, and reconnect problems.
- **Direct R1 management GATT:** authentication and TouchPad enable commands
  succeeded, but no direct gesture stream was emitted. The controller path
  remained R1 to G2.
- **Gesture customization:** the recovered command controls whether a hold may
  open the native app Menu while the display is off. It does not remap hold
  into an EvenHub event.
- **`isEventCapture`:** it routes the four supported Hub gestures to one page
  container; it does not expose long press.
- **Repeated `SHUTDOWN_PAGE(0)`:** it can participate in best-effort page
  recovery but is not a supported way to suppress the global Menu and cannot
  synthesize release timing.

## What would make exact Hub hold possible

Even Realities would need to expose one of these without switching the active
surface:

1. `LONG_PRESS_START` and `LONG_PRESS_STOP` in the EvenHub OS event enum;
2. an option to route Terminal voice-input events to the active Hub app; or
3. a supported R1 direct-input/HID stream with exclusive controller handoff.

Until then, use double press for reliable Hub interaction or Terminal for true
hold-to-talk.

[device-apis]: https://hub.evenrealities.com/docs/build/device-apis
[device-apis-audio]: https://hub.evenrealities.com/docs/build/device-apis#audio
[menu]: https://support.evenrealities.com/hc/en-us/articles/14269160297999-Menu
[asr-template]: https://github.com/even-realities/evenhub-templates/tree/main/asr
