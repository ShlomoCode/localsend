#!/bin/sh
# Temporary source-only predicate; no package version or host cache is consulted.
# Source this file, then call issue1927_mapping_status in the actual sandbox.
issue1927_mapping_status() {
  mapping_mode=$(awk '
    /^\[/ { section=$0 }
    section=="[Context]" && /^filesystems=/ {
      count++; value=substr($0,13); n=split(value,scopes,";")
      for(i=1;i<=n;i++) {
        if(scopes[i]=="!xdg-config/autostart") denied=1
        if(scopes[i]=="xdg-config/autostart:ro") { grants++; mode="read-only" }
        if(scopes[i]=="xdg-config/autostart:create") { grants++; mode="create" }
        if(scopes[i]=="xdg-config/autostart" || scopes[i]=="xdg-config/autostart:rw") { grants++; mode="read-write" }
      }
    }
    END { if(count==1 && grants==1 && !denied) print mode; else print "unavailable" }
  ' /.flatpak-info 2>/dev/null) || mapping_mode=unavailable
  if [ "$mapping_mode" = unavailable ]; then
    printf 'status=unavailable reason=effective-exact-scope-absent-or-ambiguous\n'
    return
  fi
  case ${XDG_CONFIG_HOME:-} in
    /*) ;;
    *) printf 'status=unavailable reason=sandbox-config-not-absolute\n'; return ;;
  esac
  mapping_dir=$XDG_CONFIG_HOME/autostart
  if [ ! -d "$mapping_dir" ] || [ ! -r "$mapping_dir" ] || [ ! -x "$mapping_dir" ]; then
    printf 'status=unavailable reason=sandbox-autostart-not-readable-searchable permission=%s\n' "$mapping_mode"
    return
  fi
  mapping_entry=$mapping_dir/localsend_app.desktop
  if [ -f "$mapping_entry" ] && [ -r "$mapping_entry" ]; then
    printf 'status=entry-present permission=%s\n' "$mapping_mode"
  elif [ ! -e "$mapping_entry" ] && [ ! -L "$mapping_entry" ]; then
    printf 'status=entry-absent permission=%s\n' "$mapping_mode"
  else
    printf 'status=unavailable reason=sandbox-entry-unreadable-or-nonregular permission=%s\n' "$mapping_mode"
  fi
}
