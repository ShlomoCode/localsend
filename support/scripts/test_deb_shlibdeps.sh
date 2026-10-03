#!/usr/bin/env bash
# Integration check: requires gcc, dpkg-dev, python3 and liblzma-dev on Linux.
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
cd "$temporary"
mkdir -p package/DEBIAN package/opt/localsend/lib
cat > package/DEBIAN/control <<EOF
Package: localsend-dependency-test
Version: 1.0
Architecture: $(dpkg --print-architecture)
Maintainer: LocalSend <test@example.com>
Description: Dependency resolver integration fixture
Depends: xdg-user-dirs
EOF
cat > private.c <<'EOF'
int private_value(void) { return 42; }
EOF
cat > main.c <<'EOF'
extern int private_value(void);
int main(void) { return private_value() == 42 ? 0 : 1; }
EOF
cat > plugin.c <<'EOF'
#include <lzma.h>
unsigned int plugin_version(void) { return lzma_version_number(); }
EOF
gcc -shared -fPIC private.c -Wl,-soname,libprivate.so.1 -o package/opt/localsend/lib/libprivate.so.1
gcc main.c -Lpackage/opt/localsend/lib -l:libprivate.so.1 -Wl,-rpath,'$ORIGIN/lib' -o package/opt/localsend/localsend
# This dependency exists only in a plugin, which need not be executable.
gcc -shared -fPIC plugin.c -llzma -o package/opt/localsend/lib/plugin.so
chmod 644 package/opt/localsend/lib/plugin.so
dpkg-deb --build --root-owner-group package fixture.deb
before=$(dpkg-deb --field fixture.deb Depends)
[[ "$before" == xdg-user-dirs ]]
python3 "$script_directory/deb_shlibdeps.py" fixture.deb
depends=$(dpkg-deb --field fixture.deb Depends)
[[ "$depends" == *xdg-user-dirs* && "$depends" == *libc6* && "$depends" == *liblzma5* ]]
[[ "$depends" != *libprivate* ]]
dpkg-deb --extract fixture.deb installed
installed/opt/localsend/localsend

# A linked external library with no provider must fail and preserve the artifact.
gcc -shared -fPIC private.c -Wl,-soname,libmissing.so.1 -o libmissing.so.1
gcc main.c -L. -l:libmissing.so.1 -o package/opt/localsend/localsend
dpkg-deb --build --root-owner-group package missing.deb
checksum=$(sha256sum missing.deb)
rm libmissing.so.1
if python3 "$script_directory/deb_shlibdeps.py" missing.deb > missing.log 2>&1; then
    echo 'Dependency generation unexpectedly accepted a missing library' >&2
    exit 1
fi
[[ "$(sha256sum missing.deb)" == "$checksum" ]]
grep -q 'libmissing.so.1' missing.log
echo "Verified plugin dependencies, bundled private libraries, explicit dependencies and missing-library failure: $depends"
