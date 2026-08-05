# Contributing to openhac4

Contributions are welcome. Please read the code provenance section first.

## Code provenance

openhac4 is MIT licensed, which only works if everything in it is original.

**Don't copy code from Control4 or Snap One sources** - the `docs-driverworks`
and `drivers-common-public` repositories, their sample drivers, or anything
extracted from a shipped `.c4z`. Those repos are readable, but they aren't open
source, so their code can't ship under MIT.

**Don't copy from other Control4 Home Assistant driver projects either**,
commercial or community. A project with no license file isn't free to copy from;
it just has no license.

Write from the published protocol references instead. Snap One documents each
proxy protocol separately, one site per proxy, starting from
<https://snap-one.github.io/docs-driverworks-proxyprotocol/> and covering
security, thermostat, blind, fan, lock, light v2, contact, relay, media service,
and others. The SDK index is at <https://github.com/snap-one/docs-driverworks>.

Interface constants are the exception, because there is no alternative to using
them: proxy names, connection class names, capability tag names, command and
notification names, and the DriverWorks entry-point signatures have to appear
verbatim or the driver won't talk to Control4 at all. Those are expected. The
code written around them is what should be yours.

If you aren't sure whether a source is safe to work from, open an issue and ask
before writing the code rather than after.

## Working on the project

- `src/<driver>/` holds one directory per driver: `driver.xml`, `driver.lua`, and
  `www/`.
- `common/openhac4/` holds the Lua shared across drivers. It is packed into every
  `.c4z`, so a change there affects all seventeen drivers; test more than one.
- `python3 build.py` (Python 3.9 or newer) packs each `src/<driver>` into
  `dist/openhac4_<driver>.c4z`.
- Install a rebuilt `.c4z` in Composer with Driver > Add or Update Driver or
  Agent. Control4 caches drivers aggressively, so bump the version or remove and
  re-add the driver when a change does not appear to take effect.

## Pull requests

- Describe the Home Assistant setup you tested against, including the HA version
  and the specific integration behind the entity. Behavior varies a lot between
  integrations that expose the same domain.
- Note whether you tested on real Control4 hardware and on which OS version.
- Keep unrelated formatting changes out of the diff.
