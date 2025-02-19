# v0.20.2 - XXXX-XX-XX


## Changes affecting backwards compatibility

- All `strutils.rfind` procs now take `start` and `last` like `strutils.find`
  with the same data slice/index meaning. This is backwards compatible for
  calls *not* changing the `rfind` `start` parameter from its default. (#11487)

  In the unlikely case that you were using `rfind X, start=N`, or `rfind X, N`,
  then you need to change that to `rfind X, last=N` or `rfind X, 0, N`. (This
  should minimize gotchas porting code from other languages like Python or C++.)

- On Windows stderr/stdout/stdin are not opened as binary files anymore. Use the switch
  `-d:nimBinaryStdFiles` for a transition period.

### Breaking changes in the standard library


### Breaking changes in the compiler


## Library additions


## Library changes

- Fix async IO operations stalling even after socket is closed. (#11232)

- More informative error message for `streams.openFileStream`. (#11438)


## Language additions


## Language changes


### Tool changes


### Compiler changes

- Better error message for IndexError for empty containers. (#11476)

- Fix regression in semfold for old right shift. (#11477)

- Fix for passing tuples as static params to macros. (#11423)

## Bugfixes
