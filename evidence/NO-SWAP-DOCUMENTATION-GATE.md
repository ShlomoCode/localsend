# Requested no-swap discriminator: documentation gate remains unmet

The coordinator requested the same installed Debian12/Openbox/two-CPU/1GiB receiver without swap, changing only documented VM swap policy, before a new five-file control and500/5000 Options cases. The prerequisite was to establish that this is a supported configuration. No workload or VM policy change has occurred for that request.

Independent read-only research reviewed these primary sources:

- Debian Bookworm installation requirements: https://www.debian.org/releases/bookworm/amd64/ch03s04.en.html . The table lists1GB desktop minimum, but the accompanying text assumes swap enabled and a non-live image. The previously used table therefore cannot establish the no-swap condition.
- Debian partitioning guidance: https://www.debian.org/releases/bookworm/amd64/ch06s03.en.html#di-partition and https://www.debian.org/releases/bookworm/amd64/apcs03.en.html . Swap is recommended; the cited examples do not supply a1GiB/no-swap desktop qualification.
- Official Debian Openbox package: https://packages.debian.org/bookworm/openbox . It describes the lightweight window manager but supplies no minimum RAM or no-swap guarantee.
- Openbox upstream standalone desktop instructions: https://openbox.org/help/Getting_started . These support standalone use but do not specify the needed resource/swap contract.

The examined sources do not prove the requested1GiB/no-swap configuration as a documented supported minimum. This is not a finding that no-swap installation is prohibited or that Openbox will fail. A healthy five-file application control would empirically qualify that workload, but would not replace the requested documentary prerequisite.

The distinction matters because the completed1GiB/swap case reaches approximately956MiB PSS+Swap and may avoid an OOM that a no-swap case would show; the2GiB/no-swap case retains headroom. Such a no-swap experiment could be an empirical resource/swap discriminator if the coordinator explicitly revises the rationale/condition. Reporter RAM and swap remain unknown, so neither configuration is a reporter match. No persistent delay that recovered justifies a production patch by itself.

A low-rate raw-frame stream with host-side encoding is being considered for the optional continuous clip, to avoid guest encoder memory/CPU pressure. Its measured overhead and actual timestamps would need to remain explicit; a nominal low frame rate cannot prove uninterrupted rendering.
