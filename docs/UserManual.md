# Kenwood Control — User Manual

**Kenwood Control** is a macOS app for remotely operating a Kenwood TS-890S (and compatible TS-series radios) over a local network using the Kenwood Network System (KNS) protocol and CAT commands. It provides full transceiver control, LAN audio receive and transmit, software noise reduction, MIDI tuning, memory management, and is designed to be fully accessible with VoiceOver.

---

## Contents

1. [Requirements](#requirements)
2. [First Launch](#first-launch)
3. [Connection](#connection)
4. [Radio](#radio)
5. [Audio](#audio)
6. [Equalizer](#equalizer)
7. [Memories](#memories)
8. [Menu Access](#menu-access)
9. [Connection Profiles](#connection-profiles)
10. [MIDI](#midi)
11. [Logs](#logs)
12. [FT8](#ft8)
13. [Keyboard Shortcuts](#keyboard-shortcuts)
14. [VoiceOver and Accessibility](#voiceover-and-accessibility)
15. [Troubleshooting](#troubleshooting)

---

## Requirements

- macOS 14 Sonoma or later
- Kenwood TS-890S (or compatible TS-series radio) connected to the same local network
- KNS (Kenwood Network System) enabled on the radio's LAN menu
- An administrator ID and password set in the radio's LAN menu
- The radio's IP address (check the radio's menu or your router's DHCP table)

---

## First Launch

On first launch the app opens to the **Connection** section. Before you can control the radio you need to enter:

- The radio's IP address or hostname
- The TCP port (default: **60000**)
- Your KNS administrator ID and password

These credentials are saved per host address so you only need to enter them once. After a successful connect they are remembered for future sessions.

---

## Connection

Navigate here with **Command-1** or by selecting **Connection** in the sidebar.

### Fields

| Field | Description |
|---|---|
| Host/IP | IP address or hostname of the radio (e.g. `192.168.1.20`) |
| Port | TCP port — use **60000** for direct KNS control |
| Use KNS Login | Enable for authenticated KNS sessions (required for most radios) |
| KNS Account Type | **Admin** or **User** — admin allows full control |
| Admin ID | The administrator ID set in the radio's LAN menu |
| Password | The administrator password |

Once credentials are saved, the Connection section shows a compact summary line ("Credentials saved for …") with an **Edit Credentials…** button if you need to change them.

### Buttons

- **Connect** — opens the TCP connection and performs KNS authentication
- **Disconnect** — closes the connection and stops LAN audio
- **KNS Setup Wizard** — opens a step-by-step sheet for first-time setup

### Status

The current connection state is shown below the buttons:

- **Disconnected** — not connected
- **Connecting** — TCP handshake in progress (15-second timeout)
- **Authenticating** — KNS login exchange in progress (10-second timeout)
- **Connected** — fully authenticated and ready

If an error occurs (wrong password, radio unreachable, timeout) it is shown in red below the status line. Pressing Connect again clears the error and retries.

### KNS Setup Wizard

The wizard sheet walks through the steps to enable KNS on the radio:

1. On the radio, open the LAN menu and enable KNS.
2. Set an administrator ID and password.
3. Note the radio's IP address.
4. Use TCP port 60000.
5. Enter the details in the wizard and press **Test Connection**.

The wizard also has a **Use Last Connected IP** button that fills in the IP address from the most recent successful connection.

---

## Radio

Navigate here with **Command-2** or by selecting **Radio** in the sidebar.

### VFO

| Control | Description |
|---|---|
| VFO A MHz | Enter a frequency in MHz and press Return or **Set VFO A** |
| VFO B MHz | Enter a frequency in MHz and press Return or **Set VFO B** |

Frequencies are displayed and accepted in MHz to six decimal places (e.g. `14.225000`). The fields update automatically when the radio reports a frequency change via Auto Information.

### Memory Channels

- **Memory Mode** toggle — switches between VFO and memory channel operation
- **Channel** field + stepper — select a memory channel (0–119)
- **Recall** button — activates the selected channel
- The channel's name, frequency, and mode are shown to the right

#### Program Memory

Fill in a frequency, mode, and optional name (up to 10 characters), then press **Program This Channel** to write it into the currently selected memory channel. The **Use Current VFO A** button copies the radio's active VFO A frequency and mode into the program fields.

### Transceiver Controls

#### Split

- **Split** toggle — enables split operation (RX and TX use different VFOs)
- **RX VFO** / **TX VFO** pickers — select which VFO each function uses
- **Split Offset** — enter a kHz value and press **+** or **–** to shift the TX VFO up or down

#### RIT / XIT

- **RIT** toggle — receive incremental tuning
- **XIT** toggle — transmit incremental tuning
- **Offset slider** — adjust RIT/XIT offset from −9999 to +9999 Hz; **Clear** resets to 0

#### RX Filter

Three sliders adjust the receive filter in real time:

- **Low Cut** (0–35) — controls the low-frequency edge
- **High Cut** (0–27) — controls the high-frequency edge
- **Filter Shift** (−9999 to +9999 Hz) — shifts the passband

All three apply immediately as you drag the slider.

#### TX Power / ATU

- **Power W slider** (5–100 W) — set transmit power; updates apply immediately
- **ATU TX** toggle — enables the internal ATU on transmit
- **Tune** / **Stop Tune** — start and stop ATU tuning cycle

#### Gains

- **RF Gain** (0–255) — receiver RF gain; slider and text field both work
- **AF Gain** (0–255) — audio frequency gain
- **Squelch** (0–255) — squelch threshold

#### Mode / DSP

Select operating mode using the radio group picker or the quick **LSB** / **USB** buttons. All standard modes are available: LSB, USB, CW, CW-R, FSK, FSK-R, AM, FM.

**NR** (Noise Reduction) — selects the radio's built-in noise reduction: Off, NR1, or NR2.

**Notch** toggle — enables the radio's auto-notch filter.

#### PTT

- **PTT Down (TX)** button — keys the transmitter
- **PTT Up (RX)** button — unkeys the transmitter
- **Hold Option-Space** — push-to-talk from the keyboard (works anywhere in the app)

PTT is automatically released if the app loses focus.

---

## Audio

Navigate here with **Command-3** or by selecting **Audio** in the sidebar.

### Mic / VoIP

| Control | Description |
|---|---|
| Mic Input picker | Select the microphone for LAN transmit — leave blank for the system default |
| VoIP Volume | Receive audio level sent by the radio (0–100) |
| VoIP Mic | Microphone level for transmitting over KNS (0–100) |

If PTT keys but there is no modulation, set VoIP Mic above 0 (try 50).

### Software Noise Reduction

Noise reduction runs on the received LAN audio in software, independently of the radio's built-in NR.

- **Enable** toggle — turns software NR on or off (keyboard: **Command-Shift-N**)
- **NR Profile** picker — choose **Speech** (optimised for voice) or **Static Hiss** (for broadband noise)
- **NR Strength** slider (0–100%) — how aggressively noise is removed
- **Backend** picker — switch between available noise reduction engines:
  - **RNNoise** — neural-network noise suppression; best for voice with background noise
  - **WDSP EMNR** — spectral subtraction from the OpenHPSDR WDSP library
  - **WDSP ANR** — adaptive noise reduction from WDSP

Use **Command-Control-R** to cycle through backends while operating.

### LAN RX Audio

The radio streams receive audio over UDP (port 60001) using Kenwood's VoIP protocol.

| Control | Description |
|---|---|
| Auto-start LAN audio | When enabled, audio starts automatically on connect |
| Output picker | Select the Mac speaker/headphone output |
| Refresh Audio Devices | Re-scan for newly connected audio interfaces |
| Volume slider (0.1–4.0) | Software gain on the received audio |
| Running / Stopped | Shows whether the UDP audio receiver is active |

**Packet count** and **last packet time** are shown for diagnostics. If the count is not advancing, the radio is not streaming — check that KNS VoIP is enabled on the radio (the app sends `##VP1;` on connect).

LAN audio stays bound to its UDP port across TCP reconnects so you do not lose audio when the connection briefly drops and re-establishes.

---

## Equalizer

Select **Equalizer** in the sidebar.

Adjusts the receive audio equalizer bands. Changes are sent to the radio in real time via CAT commands. Sliders apply immediately as you drag.

---

## Memories

Select **Memories** in the sidebar.

Displays the radio's memory channels in a browser list. Select a channel to see its details and recall it directly from the browser without typing a channel number.

---

## Menu Access

Select **Menu Access** in the sidebar.

Provides direct access to selected radio menu items without using the front panel. Useful for settings that are not exposed as CAT commands, accessed via the radio's menu CAT interface.

---

## Connection Profiles

Select **Profiles** in the sidebar.

Save and recall complete connection configurations — host, port, credentials, and KNS settings — as named profiles. Useful if you connect to more than one radio or use different account types.

- **Save Current** — stores the active connection settings as a new profile
- **Load** — applies a saved profile's settings to the Connection section
- **Delete** — removes a saved profile

---

## MIDI

Select **MIDI** in the sidebar.

Use a MIDI encoder (such as the CTR2MIDI) to tune VFO A with a hardware knob.

### Setup

1. Connect the MIDI device to the Mac.
2. Press **Refresh Sources** to scan for MIDI input devices.
3. Select the device from the **MIDI Source** picker.
4. Set the **MIDI Channel** (1–16) and **CC Number** (0–127) to match what the encoder sends. The CTR2MIDI factory default is Channel 1, CC 1.
5. Press **Save CC Settings** to persist these across app launches.

### Tuning Step

Choose how far VFO A moves per encoder click:

| Step | Use case |
|---|---|
| 10 Hz | Very precise SSB/CW tuning |
| 100 Hz | Normal SSB tuning |
| 1 kHz | Quick in-band moves |
| 10 kHz | Band scanning |
| 100 kHz | Fast band changes |

The step setting is saved automatically when changed.

### How the CTR2MIDI Works

The CTR2MIDI sends relative CC messages:
- Clockwise: CC value 1–63 (higher value = faster spin)
- Counterclockwise: CC value 65–127

Multiple rapid clicks in the same direction move VFO A proportionally further.

The **Last MIDI Event** box shows the most recent CC message received, useful for verifying the device is connected and sending the right channel/CC.

---

## Logs

Navigate here with **Command-4** or by selecting **Logs** in the sidebar.

### Status Summary

Shows connection state, VFO A frequency, operating mode, and the last transmitted and received CAT frames in a monospaced display.

### Connection Log

A scrollable list of timestamped connection events — authentication steps, errors, keepalive frames, and mode changes. Use **Copy Log** to paste the log into a message for troubleshooting. **Clear** empties the list.

### Smoke Test

Press **Run Smoke Test** to send a sequence of diagnostic CAT commands and verify the radio responds correctly. The result is shown in the status field.

### Errors

Displays any errors that have occurred since launch, separate from the connection log.

---

## FT8

Navigate here with **Command-5** or by selecting **FT8** in the sidebar.

Provides FT8 integration support — frequency presets and mode switching to simplify jumping to FT8 calling frequencies on each band.

---

## Keyboard Shortcuts

### View (section navigation)

| Shortcut | Action |
|---|---|
| Command-1 | Connection section |
| Command-2 | Radio section |
| Command-3 | Audio section |
| Command-4 | Logs section |
| Command-5 | FT8 section |

### Connection menu

| Shortcut | Action |
|---|---|
| Command-C | Connect (reconnect with saved settings) |
| Command-D | Disconnect |

### Audio menu

| Shortcut | Action |
|---|---|
| Command-Shift-N | Toggle software noise reduction |
| Command-Control-R | Cycle noise reduction backend |
| Command-Shift-M | Toggle audio mute |

### Mode menu

| Shortcut | Action |
|---|---|
| Control-Shift-L | Lower Sideband (LSB) |
| Control-Shift-U | Upper Sideband (USB) |
| Control-Shift-C | CW |
| Control-Shift-A | AM |
| Control-Shift-F | FM |

### Push-to-Talk

| Shortcut | Action |
|---|---|
| Hold Option-Space | PTT down (transmit) — release to return to receive |

PTT is automatically released if the app loses focus.

---

## VoiceOver and Accessibility

Kenwood Control is designed to be fully operable with VoiceOver:

- Every control has an `accessibilityLabel` describing its purpose
- Sliders include an `accessibilityValue` with the current reading in natural language units (e.g. "2400 hertz")
- Error messages are visible in the Connection section immediately below the status line — VoiceOver reads them when focus passes through, without needing to visit the Logs tab
- Decorative status indicators (coloured circles) are hidden from the accessibility tree
- PTT via Option-Space works under VoiceOver: the Option modifier state is tracked separately to account for cases where VoiceOver captures modifier key events before the app sees them
- All section navigation is available via keyboard shortcut (Command-1 through Command-5) so you never need to navigate the sidebar list
- All sliders have corresponding text fields for direct numeric entry
- Noise reduction and mute can be toggled from the Audio menu without entering the Audio section

---

## Troubleshooting

### Cannot connect — "Connection timed out"

- Verify the radio's IP address. Check the radio's LAN menu or your router's DHCP table.
- Confirm the radio has KNS enabled and LAN operation is set to active.
- Make sure port 60000 is not blocked by a firewall between the Mac and the radio.
- The radio must be on and in standby or operate mode — it does not respond to KNS when powered off.

### Authentication failed — "check Admin ID and password"

- Re-enter credentials using **Edit Credentials…** and try again.
- Credentials are ASCII only, 1–32 characters. Check for invisible trailing spaces — the app trims them automatically, but verify on the radio side.
- Confirm you are using the same account type (Admin/User) configured on the radio.

### Connected but no audio

- Check that **Auto-start LAN audio** is enabled in the Audio section, or manually verify the LAN audio shows **Running**.
- Check that the **Output** picker is set to the correct speaker/headphone device. Press **Refresh Audio Devices** if a device was connected after launch.
- The Volume slider range is 0.1–4.0; make sure it is above 0.1.
- On the radio, verify that KNS VoIP is not disabled in the LAN settings.
- If the Audio section shows a red **LAN Audio Error**, note the message — "port in use" means another app (or a previous session) is holding UDP port 60001.

### PTT keys but no modulation

- In the Audio section, raise **VoIP Mic** above 0 (try 50).
- Confirm the correct **Mic Input** device is selected.

### MIDI encoder not tuning

- Press **Refresh Sources** in the MIDI section.
- Verify the MIDI Channel and CC Number match what the encoder sends — turn the encoder and watch the **Last MIDI Event** box.
- Try saving the CC settings with **Save CC Settings** and restarting the app.

### Log file location

A diagnostic log is written to `~/kenwood-control.log`. Use `scripts/checklogs.sh` to view recent entries. This log includes connection events, audio pipeline state, PTT key events, and noise reduction diagnostics.
