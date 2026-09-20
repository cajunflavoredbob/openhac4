# Changelog

## 1.2.3
- README: the update guidance now says that the no-safe-order rule applies from
  1.2.0 onwards, and that a site still on 1.1.1 or earlier should update the
  children first, since a gateway that old keeps serving them. It also says
  what a Version Mismatch reading of NOT ENFORCED means and how to clear it.
- Gateway documentation: added a troubleshooting entry for the NOT ENFORCED
  state, in which the gateway cannot read its own version and accepts every
  child unchecked. The remedy is to re-add the gateway from a fresh package.
  The existing entry is now titled by the BLOCKED reading it describes, so the
  two no longer overlap.
- The 1.2.2 notes did not say that the gateway's Documentation tab dropped its
  per-release history list in favour of the same version line the children
  carry. The full history is this file.

## 1.2.2
- Every driver's Documentation tab now states its own version and points at the
  full changelog, instead of listing a fixed entry that went stale the first
  time the version moved. All 17 drivers use the same wording.
- README: added an Updating section stating that all openhac4 drivers must run
  the same version, that only the gateway reports an available update, and that
  a half-updated project stops working until the last driver is done.

## 1.2.1
- A driver refused over a version mismatch is now driven offline: its Entity
  Status reads "unavailable" and the drivers that report availability to
  Control4 (lock, alarm, light, media source) report it. Before this a refused
  driver kept whatever state it last held, so a lock still read "locked" and
  every command was dropped with nothing to show for it. The gateway does this
  by pushing the offline state itself, so it also reaches drivers older than
  1.2.0, which have no way to report a mismatch on their own. Most remaining
  driver types still show their last known value in Navigator and reflect the
  refusal only in Composer. The garage driver is the exception and the worse
  case: going offline opens both of its contacts, which the bound Control4
  garage proxy reads as in transit, so a refused garage door shows as opening
  or closing until the drivers are updated.
- The gateway no longer enforces versions when it cannot read its own version.
  It previously compared against an empty value and refused every driver in the
  project, blaming each of them for a fault that was the gateway's.
- The Version Mismatch property is re-established when the gateway loads. A
  mismatch resolved while the gateway was restarting used to leave the property
  reading BLOCKED permanently, which is what updating everything at once causes.
- A refused driver no longer overwrites its own mismatch banner with "Gateway
  Found" every two minutes.
- The registration tick still prompts a reconnect when a driver is refused, so a
  half-updated project can recover its Home Assistant connection on its own.
- Gateway: Driver Version falls back to the numeric version when the semantic
  version cannot be read, instead of displaying blank.
- Gateway documentation: the changelog tab lists the real release history, the
  Version Mismatch entry describes what a refused driver actually shows, and the
  update instructions say to update every openhac4 driver back to back and warn
  that from 1.2.0 onwards no update order avoids the mixed-version window.

## 1.2.0
- Strict version enforcement: the gateway refuses child drivers whose version
  does not exactly match its own. Refused drivers are named in the gateway's
  new Version Mismatch property and their Gateway Status explains the
  mismatch. Update all openhac4 drivers together.

## 1.1.1
- Gateway: the update-available message and the documentation now point at the
  GitHub releases page and the Composer update steps.

## 1.1.0
- Gateway: opt-in update check (Check for Updates property, default Off). Once
  a day it compares the driver version against the latest GitHub release and
  shows the result in Driver Version. Nothing is downloaded or installed.

## 1.0.0
Initial public release.
