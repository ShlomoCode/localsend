# Issue 513 recovery, 2026-10-11

Ownership: issue513 only, isolated `/tmp/localsend-bug-513`, branch `codex/bug-513-fedora-diagnostics`. No local builds, tests or app workloads. Maximum one fork Actions job.

Original report: Fedora 38 Workstation, Flatpak, Downloads drop works; Documents drop raises PathNotFoundException. Seven comments reread. Report dated 2023-06-07; package manifest at that date was 1.10, not 1.9. Current official artifact is separately identified, not claimed historical reproduction.

Recovered baseline artifact: official Flathub 1.18.2, OSTree commit a7a6bc3f9debbbfd90c2e8874a83a5606db10b53dffc187449b0684991e7740c, default xdg-download only, no filesystem overrides, desktop_drop0.7.1. Fedora38 GNOME44.10/Nautilus44.3.1/portal1.16, real Wayland and USB input. Downloads38B drop works; Documents drop fails three fresh process repetitions; same Documents file actual chooser works through document portal.

Run38158347988 head3cc6ecb698dfb4de89e944cde3991308a6b33b29 recovered to `/tmp/bug513-run38158347988`: receiver real app runs as separate user, veth192.168.51.2/netns, port53317; final input stops at blank manual address dialog. Receiver Downloads empty. Green job is not transfer evidence.

Run38161902906 headf229462e389ee6dde7035ec566ad13d48c224f9a recovered to `/tmp/bug513-run38161902906`: manually register192.168.51.2 initiated real send immediately, receiver session destination `/home/receiver/Downloads`, visible receiver wants-to-send approval. Actual Accept at x615,y720; previous input x745,y650 missed. No saved file. Revised d0101eb4ea277b6e8a565ddc05ddd75ae33ad992 runs38162404134: observed button coordinates,10s accept clip, sender result and required saved-content cmp.

Raw source/receiver control SHA256:36aabe64cd3982dcc14a62827fddc2547d78316cbf8e5a4f790d0c5958a8e7f1,38bytes.

Exact dependency correcting commit af1fb55a82eab1912e6bb8a11d5bf284f7ed687d (released0.8.1) registers portal MIME priority and resolves RetrieveFiles. Existing upstreamPR3373 authoredloucass bumps0.8.4. Versions0.8.2-0.8.4 change Android only. Current0.8.4 source2ef30a7e96c185c926a7a2d210fc5f6b7d803248. Exact lib/Linux reverse patch checked cleanly against0.8.4 locally using source-only git management. No production patch/PR.

Run38162404134 actual app control passed. Read raw saved-file size38 and both SHA256 values36aabe64cd3982dcc14a62827fddc2547d78316cbf8e5a4f790d0c5958a8e7f1, plus cmp pass marker. Viewed images18pending/19receivingDone/20sendingDone. Original10s receive-accept clip150frames15fps decoded at frames0/45/120: pending→Done. Root independently accepted this raw evidence.

Cloud source comparison: source c1ce322fb3acf08e44f329b8b7208b8b0d91e244/Flutter3.41.9; normal0.7.1;0.8.4 with exact af1fb55 lib/Linux diff reversed; unchanged0.8.4. Causal pair pubspec/version/deps identical. Initial Flathub manifest assembly of each full source-built tar. Published0.8.4 archiveSHA25647ded09c85909edfed644fd4cbb5051b040d0aed5c79e7e062ea4b3b7156dbe4 matches candidate entire lib/Linux trees and pubspec. Source0.7.1 releasea3e2d018→preportalec7f83b has no lib/Linux changes.

Buildrun38162971888 headbb62f3427cf11f28ee21cbe23ffbac5296f2dad9: normal app built, source-diff-normal empty; packaging failed because SDK26/CMake4.4 installed ido into/app/lib64 while indicator pkg-config expects/app/lib. Raw `/tmp/bug513-build38162971888/issue513-causal-source-packages-38162971888/package-normal.txt`. Corrected supported CMake install-dir config uniformly on auxiliary CMake modules in initial manifest. Head10f075ddc28915b1d20ef0d9feab0c124ff2624e runs38163717100; only source build active, Fedora job skipped.

Prepared next `.github/workflows/diagnose-513-causal-ui.yml` (uncommitted pending build result) reads retained source bundles, boots the same Fedora38/Wayland and records loaded package hash/manifest/lock. Normal/negative retain failing Documents drop then actual chooser→send/approve/save control. Positive sends actual final Documents-drop selection directly, with the same peer approval/content check. Source c1ce manual address uses its actual hashtag UI (#2 on veth prefix). No production patch/PR until raw cause comparison passes.
