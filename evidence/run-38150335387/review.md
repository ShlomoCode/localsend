# Cloud sparse gate stopped before physical session

Owned run [38150335387](https://github.com/ShlomoCode/localsend/actions/runs/38150335387), head `7bff128b`, passed syntax checks and paired helper Java/dex/signature builds. It stopped in the runner-only cloud transport check before the BrowserStack step; no physical session or original-app transfer was attempted.

Authentication, duplex before HTTP EOF, duplicate rejection, isolated abort/cancel, healthy-peer count/hash, and coalesced batch/explicit TCP EOF controls passed. Sparse progress logs continue through 300 seconds. The final error is `Request did not remain open beyond Node default 300 seconds`; total check duration is 310216 ms.

The assertion combines three conditions: not stopping, sparse duration at least 310000 ms, and request not destroyed. The raw failure does not preserve those individual values or relay upload state. Total duration includes earlier controls and cleanup and cannot prove the sparse interval itself reached its deadline. An early timer or clock edge is plausible, but request destruction is not ruled out. This run does not establish a transport regression or a successful sparse gate.

The diagnostic check will use a finite monotonic deadline loop, separate condition assertions, and preserve the request/relay/target state before cleanup on either outcome. The greater-than-300-second open-request, true EOF and count/hash requirements remain unchanged. Raw artifact 11706683208 is preserved locally. There is no active owned job/session; accepted product conditions remain four and the reporter ANR remains unreproduced.
