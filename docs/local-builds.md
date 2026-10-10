# Separate Stable and Dev apps

| App | Build | Bundle identity | Library |
| --- | --- | --- | --- |
| Petrichor Stable | Release, pinned at `local-stable-v2` | `org.Petrichor.zak.stable` | Its own sandbox container |
| Petrichor Dev | Debug, development checkout | `org.Petrichor.zak.debug` | Its own sandbox container |

The original `org.Petrichor` app remains separate. Both local apps have distinct
URL schemes, preferences, logs, playback sessions, library databases, and Last.fm
credential keys. Last.fm sign-in is independent for each app.
Upstream automatic updates are disabled by the existing non-production identity
check, so they cannot replace the local fixes. These are locally signed builds;
each app needs its own permission to read a watched music folder.

## Development

Work in the main source checkout on `dev/local-customizations`:

```sh
./Scripts/build-local.sh dev
```

The output is `.local-build/dev/Build/Products/Debug/Petrichor Dev.app`.
Xcode Debug builds also use the same Dev identity and URL scheme.
Installing a newer Dev app updates only that app; keep its container intact.
The development icon differs from the Stable app's normal icon.

## Stable

The Stable checkout is `.worktrees/stable`, detached at `local-stable-v2`.
The build script refuses to build Stable from a different commit or with tracked
source changes. To reproduce the installed Stable app:

```sh
cd .worktrees/stable
./Scripts/build-local.sh stable
```

Both checkouts use the same build cache. Set `PETRICHOR_LOCAL_BUILD_ROOT` to use
another cache directory. Both builds use the committed package versions and
the local ignored `Secrets.xcconfig`; blank API credentials disable the optional
online integrations that require them.

## Initial libraries

Seed each app from its own copy of a consistent SQLite backup. The optional
copied-library regression test can export its cleaned result by setting
`PETRICHOR_REGRESSION_OUTPUT` to a new file path. Never copy a running app's
database without using SQLite's backup API, and never reuse one writable database
between the two apps.

To grant folder access without deleting the existing library, use **Add Music
Folder** and select the same watched folder. The existing folder row is updated
with the new app's bookmark; playlists and saved track data are retained.
