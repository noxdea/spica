# fzy oracle sources

Unmodified sources from [jhawthorn/fzy](https://github.com/jhawthorn/fzy/tree/34b88869d022e861da4846c4463aea3ddfb3ff30), commit `34b88869d022e861da4846c4463aea3ddfb3ff30`; MIT, see LICENSE.

The tests reproduce upstream's build layout in a temporary directory, compile match.c with its original bonus.h/config.def.h, and feed batches to the small driver in test/support/fzy_oracle.c. No C code is built, installed or loaded by the library. All eight ranking assertions in upstream test_match.c are read and checked. Random ASCII score comparisons exercise the actual upstream dynamic programming implementation. Empty/overlong behavior and Unicode/path-specific enhancements intentionally exceed fzy's byte-oriented contract.
