# Hardware design

## Recommended sensor class

Use a **3.3 V UART capacitive fingerprint module with local matching and
template flash**, such as an R503/R502/R559S-class module.

This class is appropriate because:

- it performs image capture, feature extraction, enrollment, template storage,
  and 1:N matching inside the sensor;
- the Pi receives only a result, template ID, and score—not fingerprint images
  or templates;
- it uses the Pi GPIO UART, leaving the Pi Zero's USB OTG port available for
  its existing composite USB gadget;
- panel-mount capacitive units are practical for a desk enclosure.

Do not start with USB fingerprint readers. The Pi's OTG port is already in
USB-device mode to emulate the ZeroBridge composite gadget. USB host readers
require a hub, additional power, and change the simple tethered topology.

Avoid raw-image SPI sensors for v1. They put biometric processing and templates
on the Pi's SD card/Linux environment, which is both more work and a worse
privacy boundary.

## Initial bill of materials

| Item | Recommendation | Why |
|---|---|---|
| Host | Raspberry Pi Zero 2 W preferred; Zero W workable | Zero 2 W has more headroom; both support gadget mode |
| Sensor | R503/R502/R559S-class 3.3 V UART capacitive reader | Sensor-local matching and panel mount |
| Power switching | 3.3 V load switch or P-channel MOSFET | Let the Pi fully power-cycle the sensor |
| Wiring | Four signal wires plus 3.3 V/GND; JST breakout as needed | UART, touch/interrupt, optional reset |
| Enclosure | Nonconductive enclosure with sensor cutout | Protect wiring and prevent sensor strain |
| USB cable | OTG-capable data cable | Existing keyboard/mouse/network gadget path |

Verify the exact sensor revision's datasheet before wiring. Pin colours,
available interrupt/reset pins, storage capacity, packet variants, and
recommended supply current vary between suppliers.

## Wiring

Typical R503/R559S-class wiring:

| Sensor signal | Pi Zero connection | Notes |
|---|---|---|
| VCC | Switched 3.3 V | Never assume a 5 V-tolerant variant |
| GND | Pi ground | Shared ground is required |
| TXD | Pi UART RX, GPIO 15 | Crossed UART connection |
| RXD | Pi UART TX, GPIO 14 | Crossed UART connection |
| Touch / WAKE | Spare input GPIO | Optional but strongly recommended |
| RESET | Spare output GPIO | Optional; use if exposed by the chosen module |
| SENSOR_EN | GPIO → load switch enable | Pi controls sensor power |

The Pi header UART and ZeroBridge's `/dev/ttyGS0` are unrelated:
`/dev/ttyGS0` is the USB gadget's CDC-ACM serial endpoint; the fingerprint
sensor must use the GPIO UART (`serial0`, normally GPIO 14/15).

## Pi UART configuration

The expected module settings are commonly 57,600 baud with 8 data bits, no
parity, and two stop bits (8N2). Confirm from the module data sheet.

On Pi Zero W, the stable PL011 UART is often assigned to Bluetooth. For a
reliable fingerprint UART:

1. Enable the primary UART in `/boot/firmware/config.txt` (or the
   distribution-equivalent boot configuration).
2. Use `dtoverlay=miniuart-bt` to move Bluetooth to the mini-UART, or disable
   Bluetooth if it is not needed.
3. Disable the serial login console.
4. Configure the port explicitly for 8N2 before opening it.
5. Test hot reconnects and power cycles; do not rely on a single successful
   enrollment as validation.

Do not use a USB-to-UART adapter for v1 unless it is separately powered and
tested with gadget mode. GPIO UART is simpler and leaves USB topology intact.

## Power and thermal design

The Pi is normally powered by the tethered Mac. The sensor's capture current
is small relative to Pi operation, but continuous capture plus Wi-Fi plus USB
gadget traffic can create brownouts on weak ports/cables.

Required behavior:

- use the sensor touch/interrupt output to wake processing;
- issue the sensor's sleep command when idle;
- cut sensor power after an idle timeout if the module's sleep mode is
  unreliable;
- serialize enrollment/matching and do not poll 1:N search continuously;
- test with the actual Mac port and cable used daily.

The Pi cannot match Immurok's low-power battery design. It is a tethered desk
appliance, not a month-long wireless key.

## Mechanical and privacy requirements

- Keep the UART wiring inside the enclosure; exposed RX/TX makes injection
  easier for an attacker with physical access.
- Mount the sensor so repeated finger pressure is borne by the enclosure, not
  solder joints.
- Do not route or retain raw sensor image data even if a vendor command exists.
- Add a visible LED or UI state for ready, matching, accepted, rejected,
  enrolling, and sensor fault.
- Enforce an explicit physical reset/enrollment action; remote enrollment is
  out of scope for v1.
