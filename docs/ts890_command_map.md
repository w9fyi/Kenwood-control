# TS-890S Command Map (v0.1)

This is a working summary of the TS-890S PC control command interface for our macOS client. It is intentionally concise and focuses on the parts we need first.

Sources
- TS-890S PC CONTROL COMMAND Reference Guide (Kenwood)
- TS-890S KNS Setting Manual (Kenwood)

## LAN session handshake (required for TCP/IP control)
- Configure IP address and administrator ID/password in the radio's LAN menu.
- Open a TCP connection to the radio.
- Send the connect command: `##CN`.
- When a connection response arrives, authenticate with `##ID` using your admin ID and password.
- If authentication succeeds, the session is established.
- If there is no communication for about 10 seconds, the radio terminates the TCP/IP connection.

Example authentication string (from Kenwood doc example):
- `##ID00705kenwoodadmin;`
  - Interprets as: account type `0` (administrator), account length `07`, password length `05`, then `kenwood` + `admin`.
  - Kenwood also supports account type `1` (KNS User), which can be configured as RX-only in the radio.

## Command framing basics
- Command name is 2 to 5 alphanumeric characters.
- Parameters are fixed-width and command-specific.
- Commands end with a semicolon `;`.
- Read command: send the command with no parameters (example: `FA;`).
- Set command: send the command with parameters (example: `FA00007000000;`).

## Error responses
- `?;` for command syntax issues or command rejected due to current radio state.
- `E;` for a communications error such as framing or overrun.
- `O;` for receive buffer overrun.

## Encoding and character set
- LAN connector uses TCP/IP.
- Character encoding mode is UTF-8.
- Character coding is ASCII-based. Bytes `0x80` to `0xFF` depend on the radio's Menu 9-01 (Keyboard Language).
- Japanese setting: ISO-2022-JP
- Other settings: ISO-8859-1

## Auto Information (AI) function
- When AI is enabled, the radio pushes state changes (for example, VFO A frequency) without polling.
- AI can be enabled/disabled per connector and is controlled via the `AI` command.
- We should enable AI for real-time UI updates. This app enables `AI2;` after the session is established.

## KNS-related control commands
- `##KN0` sets or reads KNS operation state (LAN or Internet). Requires admin login for setting.
- `##KN1` updates administrator ID/password. Requires admin login.

## Minimal command mapping for MVP (confirmed examples)
| Feature | Command(s) | Notes |
| --- | --- | --- |
| Connect + login | `##CN`, `##ID` | Required for LAN TCP control |
| VFO A frequency | `FA` | Example in doc: `FA00007000000;` |
| Auto info | `AI` | Use for push updates |
| RX/TX state (AI only) | `RX`, `TX` | Responses are output only when AI is ON |
| Operating mode | `OM` | `OM0;` reads the left frequency display area mode |
| S-meter / power | `SM` | Reads S-meter during RX, power meter during TX |
| Notch | `NT` | 0/1 |
| Noise reduction | `NR` | 0/1/2 |
| Squelch | `SQ` | 000-255 |
| KNS operation | `##KN0` | Requires admin login |
| Admin ID/pass | `##KN1` | Requires admin login |

## TODO: Expand this map from the command tables
- Add core RX/TX controls: mode, filter width/shift, AGC, NR, notch, IF shift, APF.
- Add PTT control and TX audio source selection.
- Add split, RIT/XIT, A/B VFO controls.
- Add meter queries (S, ALC, SWR, power).
- Add memory channel ops and menu read/write where needed.
- Add spectrum/bandscope output commands if we need visual scope data.

## Notes for implementation
- Keep a heartbeat to avoid the ~10 second idle disconnect.
- Parse error responses and surface them in a screen-reader friendly log.
