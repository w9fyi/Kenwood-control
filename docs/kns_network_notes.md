# TS-890S KNS Network Notes (v0.1)

These notes summarize the network behavior and ports described by Kenwood for TS-890S remote operation.

Sources
- TS-890S KNS Setting Manual (Kenwood)
- TS-890S PC CONTROL COMMAND Reference Guide (Kenwood)

## Operation styles
- Direct remote control: the TS-890S itself is the host for LAN/Internet control.
- Conventional system: a host PC runs ARHP-890, and the remote PC runs ARCP-890/ARVP-10.

## Ports and transport (direct control)
- Control channel: TCP port 60000.
- Audio channel: UDP port 60001.
- Kenwood notes the TS-890S port numbers cannot be changed.

## Ports and transport (conventional system)
- Control channel (ARHP-890): TCP port 50000 (default).
- Audio channel (ARVP-10): UDP port 33550 (default).

## Router and firewall requirements
- Port forwarding is required on the router for Internet operation.
- For direct control, forward TCP 60000 and UDP 60001 to the radio.
- For the conventional system, forward TCP 50000 and UDP 33550 to the host PC as needed.

## Audio and VoIP settings to mirror
- Built-in VoIP settings are required when using the radio as the host.
- Jitter buffer setting affects audio stability under jittery connections.
- Speaker mute setting affects how local audio is handled when remote is active.
- Timeout timer governs how long remote connections are kept alive.
- TX audio input path selection affects which source is transmitted.

## Open questions (likely requires packet capture)
- UDP audio framing and codec specifics are not described in the KNS manual.
- If we need native audio, sniffing ARCP-890/ARVP-10 traffic may be necessary.
- If not, we can start by pairing our control app with Kenwood's own audio tools.

## Implementation implications
- Use the TS-890S PC commands over the TCP control channel once the KNS connection is authenticated.
- Maintain a keepalive or periodic polling to avoid idle disconnects.
