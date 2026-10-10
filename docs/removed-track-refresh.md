# Removed tracks remaining in the library

The refresh scanner previously fetched deletion candidates with `getTracksForFolder`.
That presentation query excludes duplicates when **Hide duplicate tracks** is enabled.
Missing duplicate rows therefore survived a completed refresh. Duplicate detection could
subsequently promote those rows to primary tracks, making them visible again.

The completed refresh saved the current filesystem hash. Later ordinary refreshes
could skip the folder because that hash matched, even though its database still held
missing files.

The fix fetches all deletion candidates with a throwing, unfiltered database query.
Ordinary refresh planning also checks indexed file paths before accepting an unchanged
filesystem hash. Finding a missing path requests a scan; it does not delete anything
directly. The scanner still requires a readable root and complete enumeration before
removing entries.

## Verification

The regression suite covers hidden missing tracks, stale matching hashes, unchanged
folders, retained track IDs/favorites/play counts/playlist membership, empty folders,
unavailable roots, and an unreadable supported audio file. Its optional copied-library
case checks that all existing track IDs and saved user data survive cleanup.

Run from the project root:

```sh
xcodebuild test \
  -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/petrichor-build/DerivedData \
  -clonedSourcePackagesDirPath /tmp/petrichor-build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ENABLE_APP_SANDBOX=NO
```

To include a real library, append:

```sh
PETRICHOR_REGRESSION_DATABASE=/path/to/library-backup.db
```

Supply a consistent SQLite backup, not an active WAL database file. The test copies
that backup into its own fixture directory, clears bookmarks only in the copy,
and reads the existing music files. It never writes to the supplied backup or music.
The test host uses the separate Debug bundle/database; this does not verify the
Release app's sandbox permissions or hands-on UI behavior.
