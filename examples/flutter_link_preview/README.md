# MetaLink Flutter showcase

This native Flutter application builds a custom link preview directly from
`package:metalink`. It replaces the discontinued `metalink_flutter` package as
the maintained reference for Flutter developers.

The separation is intentional:

- MetaLink owns fetching, parsing, ranking, caching, request safety, lifecycle,
  structured failures, and diagnostics.
- The application owns state, layout, typography, navigation, images, and every
  other product-specific UI decision.

## Run it

From this directory:

```shell
flutter pub get
flutter run
```

The project includes Android, iOS, Linux, macOS, and Windows runners. Web is
omitted because third-party pages commonly reject browser requests through
CORS, and browsers do not expose every redirect hop required by strict request
policies. A Flutter web application should perform extraction through a
policy-aware server or custom MetaLink `Fetcher`.

## What the sample demonstrates

- A long-lived `MetaLinkClient` with a secure request policy.
- Operation-wide deadlines, cancellation, and caching.
- Complete, partial, and failed extraction states.
- Ranked image and favicon candidates.
- Field provenance, cache status, and timing diagnostics.
- A responsive Material 3 card built entirely inside the application.
- Deterministic engine disposal and deterministic widget tests.

The card is an educational starting point, not another stable widget API. Copy
it, restyle it, or replace it with the design system your application already
owns.

See the [MetaLink README](../../README.md) for the complete engine API.
