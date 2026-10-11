# Result-field erratum

The raw `scenario-results.json` from run 38108693595 records `sourceMatches: false` for `ascii105000`. That field was generated as `name === "short"`: only the short fixture receives the supplementary XML full-text assertion. The false value means **not checked**, not a mismatch. The raw artifact is preserved unchanged.

The complete content assertion is `clipboardVerified: true`, verified by comparing the Windows UTF-8 source with the Android clipboard readback. Both are 105000 bytes and have SHA-256 `83b801b3087bde5b41b2309cd1e364dbcccf7d9a8c86652a8479e08d3bffaf5a`.

Runs 38109163891 (multiline) and 38109605530 (105 KiB) use the same field semantics. Their full-content assertions also passed. Diagnostic runs on 721bfc80 and later emit `sourceMatches: null` when the supplementary assertion is not performed.
