# Security policy

## Supported versions

Only the latest release on [GitHub Releases](https://github.com/ozanhakantunca/keyshift/releases) receives security fixes.

## Reporting a vulnerability

Please report privately, not in a public issue: open the repository's **Security** tab and choose
[**Report a vulnerability**](https://github.com/ozanhakantunca/keyshift/security/advisories/new).

Include the Keyshift and macOS versions, what you observed, steps or a config file that reproduce it,
and what an attacker could gain.

## Scope

Keyshift holds Accessibility and Input Monitoring permissions, so it sees every key press. In scope:

- anything that lets another process or user abuse those permissions, read keystrokes, or control the
  app (for example through the command-line socket);
- the config file's ability to run shell commands being reachable without the user's intent (a crafted
  preset or Karabiner import, for instance);
- tampering with the release DMG or build pipeline.

Not in scope: commands the user wrote into their own config file, and the lack of Apple notarization
(the app is signed with a self-signed certificate, as documented in the README).

## What to expect

Keyshift is maintained by one person. You should get an acknowledgement within about a week, and a fix or
a clear explanation as soon as possible. Reporters are credited in the release notes unless they
prefer otherwise.
