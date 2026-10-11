# NVIDIA / Linux GNOME availability

Read-only inventory check on 2026-10-11. No session, runner, VM, build, or billing change was created.

BrowserStack authenticated catalog reads returned HTTP 200:

| Catalog | Inventory |
| --- | --- |
| App Automate devices | 110 combinations: iOS 63, Android 47 |
| Automate browsers | 5,240 combinations: Windows 1,476, OS X 3,586, iOS 108, Android 70 |
| App Automate plan | Device Cloud; account/team maximum five concurrent sessions |

Neither catalog contains Linux or GNOME. The plan read does not establish access to a Linux desktop or NVIDIA hardware. Raw catalog responses, without authorization headers, are in `availability/3033-bs-{devices,plan,browsers}.json`.

The authorized fork's repository Actions runners API returned `total_count: 0` and `runners: []`: no configured self-hosted runner. The inspected workflow definitions use standard GitHub-hosted Ubuntu/Windows runners; the diagnostic GNOME VM uses virtio-vga-gl. No ready NVIDIA/Linux GNOME environment was found in this checked inventory.

Eligibility for paid larger hosted GPU runners was not established. This inventory result is not a statement that no such cloud service exists and is not evidence that hardware causes issue 3033. The LocalSend report omits GPU identity; NVIDIA RTX 5090 / driver 580.82.09 appears only in the author's linked Flutter report.
