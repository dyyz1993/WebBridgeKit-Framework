# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository
(Security → Report a vulnerability) instead of opening a public issue. Include
the affected type or file and a way to reproduce it. You can expect an
acknowledgement within a few days.

## What is worth reporting

This framework decides what an iOS or macOS host app may trust. In
particular:

- Accepting an HTML app manifest, an offline package, or a gateway response
  whose signature, origin restrictions, key id, or version is not valid.
- Running a native action that the app's signed manifest does not declare, or
  that the user did not authorize.
- Loading app content from an origin outside the manifest's allow list, or
  escaping the isolation between apps.
- Reading another app's offline packages, cached data, or keychain items.

Report problems in an app built with the framework to that app's maintainer,
and problems in a self-hosted gateway to its operator.
