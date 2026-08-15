# Changelog

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
