#!/usr/bin/env bash
# Scan, apply or verify a version bump, following the detected ecosystem's own
# version format (see references/conventions.md -- that file is the contract
# for everything below).
#
#   version_bump.sh scan   [--type=T] [--manifest=P]
#   version_bump.sh apply  <old> <new> [--type=T] [--manifest=P] [--force]
#                          [--dry-run] [--also=PATH ...]
#   version_bump.sh verify <old> <new> [--type=T] [--manifest=P]
#
# Model: detected TYPE -> SCHEME (version grammar + bump arithmetic).
#   semver    node rust generic     pep440  python        rver  r
#   rubygems  ruby                  gomod   go            maven maven
#   composer  php
# Each scheme parses ONLY its canonical grammar; anything else stops with
# exit 3 instead of being guessed at.
#
# Exit codes: 0 ok | 1 usage/environment | 2 refused (mismatch, wrong <old>,
#             nothing changed, post-check failed) | 3 unsupported/unparseable.
#
# `apply` edits the declared version field(s) only (manifest + non-lockfile
# secondary locations). Other files containing the old string are listed by
# `scan` and are rewritten only when named with --also. Never commits or tags.
# Written for bash 3.2 (macOS system bash): no mapfile, no assoc arrays.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: version_bump.sh scan   [--type=T] [--manifest=P]
       version_bump.sh apply  <old> <new> [--type=T] [--manifest=P] [--force]
                              [--dry-run] [--also=PATH ...]
       version_bump.sh verify <old> <new> [--type=T] [--manifest=P]
types: r rust node python python-setuptools ruby php go maven generic
EOF
  exit 1
}

die() { local c="$1"; shift; echo "$*" >&2; exit "$c"; }

cmd="${1:-}"
shift || true
case "$cmd" in scan|apply|verify) ;; *) usage ;; esac

type_override=""; manifest_override=""; force=""; dry=""
also=(); pos=()
for a in "$@"; do
  case "$a" in
    --type=*) type_override="${a#--type=}" ;;
    --manifest=*) manifest_override="${a#--manifest=}" ;;
    --also=*) also+=("${a#--also=}") ;;
    --force) force=1 ;;
    --dry-run) dry=1 ;;
    --*) die 1 "unknown flag: $a" ;;
    *) pos+=("$a") ;;
  esac
done
set -- "${pos[@]+"${pos[@]}"}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die 1 "Not inside a git repository ($PWD). cd into the project you" \
           "want to bump, then re-run."
cd "$repo_root"
git rev-parse --verify -q HEAD >/dev/null \
  || die 1 "This repository has no commits yet; commit once so" \
           "history-based hints work."

# ============================================================ detection ====
proj_type=""; manifest=""; scheme=""

detect() {
  local g types="r|rust|node|python|python-setuptools|ruby|php|go|maven|generic"
  if [ -n "$type_override" ]; then
    proj_type="$type_override"
  elif [ -f DESCRIPTION ]; then proj_type="r"
  elif [ -f Cargo.toml ]; then proj_type="rust"
  elif [ -f package.json ]; then proj_type="node"
  elif [ -f pyproject.toml ] \
      && grep -Eq '^\[(project|tool\.poetry)\]' pyproject.toml; then
    proj_type="python"
  elif [ -f setup.cfg ] || [ -f setup.py ]; then proj_type="python-setuptools"
  elif [ -f pyproject.toml ]; then proj_type="python"
  elif ls -- *.gemspec >/dev/null 2>&1; then proj_type="ruby"
  elif [ -f composer.json ]; then proj_type="php"
  elif [ -f go.mod ]; then proj_type="go"
  elif [ -f pom.xml ]; then proj_type="maven"
  elif [ -f VERSION ]; then proj_type="generic"
  else
    die 1 "Could not auto-detect a manifest (DESCRIPTION, Cargo.toml," \
      "package.json, pyproject.toml, setup.cfg/py, *.gemspec," \
      "composer.json, go.mod, pom.xml, VERSION)."$'\n'"Re-run with" \
      "--type=<$types> [--manifest=<path>]."
  fi
  if [ -n "$manifest_override" ]; then
    manifest="$manifest_override"
  else
    case "$proj_type" in
      r) manifest="DESCRIPTION" ;;
      rust) manifest="Cargo.toml" ;;
      node) manifest="package.json" ;;
      python) manifest="pyproject.toml" ;;
      python-setuptools)
        if [ -f setup.cfg ]; then manifest="setup.cfg"
        else manifest="setup.py"; fi ;;
      ruby) for g in *.gemspec; do manifest="$g"; break; done ;;
      php) manifest="composer.json" ;;
      go) manifest="go.mod" ;;
      maven) manifest="pom.xml" ;;
      generic) manifest="VERSION" ;;
      *) die 1 "Unknown --type=$proj_type" ;;
    esac
  fi
  [ -f "$manifest" ] || die 1 "Manifest not found: $manifest"
  case "$proj_type" in
    r) scheme="rver" ;;
    rust|node|generic) scheme="semver" ;;
    python|python-setuptools) scheme="pep440" ;;
    ruby) scheme="rubygems" ;;
    go) scheme="gomod" ;;
    maven) scheme="maven" ;;
    php) scheme="composer" ;;
  esac
}

other_manifests() {
  local f out=""
  for f in DESCRIPTION Cargo.toml package.json pyproject.toml setup.cfg \
           setup.py composer.json go.mod pom.xml VERSION *.gemspec; do
    [ -f "$f" ] || continue
    [ "$f" = "$manifest" ] && continue
    case "$proj_type" in
      python*) case "$f" in
                 pyproject.toml|setup.cfg|setup.py) continue ;;
               esac ;;
    esac
    out="$out $f"
  done
  echo "$out"
}

# ============================================= field readers / writers ====
# Value of `key` inside any of the space-separated [headers] of a TOML file.
toml_table_value() { # file "[h1] [h2]" key
  awk -v hdrs="$2" -v key="$3" '
    { h=$0; sub(/[[:space:]]*(#.*)?$/,"",h) }
    h ~ /^\[/ { f = (index(" " hdrs " ", " " h " ") > 0); next }
    f && $0 ~ "^" key "[[:space:]]*=" {
      v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); q=substr(v,1,1)
      if (q=="\"" || q=="\047") { v=substr(v,2); i=index(v,q); print substr(v,1,i-1); exit }
    }' "$1"
}

toml_table_set() { # file "[h1] [h2]" key old new
  local tmp; tmp="$(mktemp)"
  awk -v hdrs="$2" -v key="$3" -v old="$4" -v new="$5" '
    { h=$0; sub(/[[:space:]]*(#.*)?$/,"",h) }
    h ~ /^\[/ { f = (index(" " hdrs " ", " " h " ") > 0); print; next }
    f && !done && $0 ~ "^" key "[[:space:]]*=" {
      s=$0; v=s; sub(/^[^=]*=[[:space:]]*/,"",v); q=substr(v,1,1)
      if (q=="\"" || q=="\047") {
        r=substr(v,2); i=index(r,q)
        if (substr(r,1,i-1)==old) { p=index(s,q old q); s=substr(s,1,p-1) q new q substr(s,p+length(q old q)); done=1 }
      }
      print s; next }
    { print }' "$1" > "$tmp"
  cat "$tmp" > "$1"; rm -f "$tmp"
}

ini_value() { # file section key   (unquoted values, setup.cfg style)
  awk -v sec="$2" -v key="$3" '
    { h=$0; sub(/[[:space:]]+$/,"",h) }
    h ~ /^\[/ { f=(h==sec); next }
    f && $0 ~ "^" key "[[:space:]]*=" { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v); print v; exit }' "$1"
}

ini_set() { # file section key old new
  local tmp; tmp="$(mktemp)"
  awk -v sec="$2" -v key="$3" -v old="$4" -v new="$5" '
    { h=$0; sub(/[[:space:]]+$/,"",h) }
    h ~ /^\[/ { f=(h==sec); print; next }
    f && !done && $0 ~ "^" key "[[:space:]]*=" {
      v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v)
      if (v==old) { p=index($0,old); print substr($0,1,p-1) new substr($0,p+length(old)); done=1; next } }
    { print }' "$1" > "$tmp"
  cat "$tmp" > "$1"; rm -f "$tmp"
}

# Top-level (brace depth 1) "version" of a JSON file. Needs one key per line.
json_top_value() {
  awk '
    { line=$0; s=line; gsub(/"([^"\\]|\\.)*"/,"\"\"",s)
      if (depth==1 && !found && line ~ /^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"/) {
        v=line; sub(/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); print v; found=1 }
      n=gsub(/\{/,"{",s); m=gsub(/\}/,"}",s); depth+=n-m }' "$1"
}

json_top_set() { # file old new
  local tmp; tmp="$(mktemp)"
  awk -v old="$2" -v new="$3" '
    { line=$0; s=line; gsub(/"([^"\\]|\\.)*"/,"\"\"",s)
      if (depth==1 && !found && line ~ /^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"/) {
        match(line,/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"/); pre=substr(line,1,RLENGTH); rest=substr(line,RLENGTH+1)
        i=index(rest,"\""); if (substr(rest,1,i-1)==old) { line=pre new substr(rest,i); found=1 } }
      print line
      n=gsub(/\{/,"{",s); m=gsub(/\}/,"}",s); depth+=n-m }' "$1" > "$tmp"
  cat "$tmp" > "$1"; rm -f "$tmp"
}

# <version> that is a direct child of the root element of a POM (never
# <parent>, <dependency>, <plugin>...). One tag per line, as Maven writes it.
pom_value() {
  awk '
    { line=$0; gsub(/<!--[^>]*-->/,"",line)
      while (match(line,/<[^<>]+>/)) {
        tag=substr(line,RSTART,RLENGTH); rest=substr(line,RSTART+RLENGTH); line=rest
        if (tag ~ /^<[?!]/ || tag ~ /\/>$/) continue
        if (tag ~ /^<\//) { depth--; continue }
        depth++
        if (tag=="<version>" && depth==2 && !found) { t=rest; sub(/<.*/,"",t); print t; found=1 }
      } }' "$1"
}

pom_set() { # file old new
  local tmp; tmp="$(mktemp)"
  awk -v old="$2" -v new="$3" '
    { line=$0; cur=$0; gsub(/<!--[^>]*-->/,"",cur)
      while (match(cur,/<[^<>]+>/)) {
        tag=substr(cur,RSTART,RLENGTH); rest=substr(cur,RSTART+RLENGTH); cur=rest
        if (tag ~ /^<[?!]/ || tag ~ /\/>$/) continue
        if (tag ~ /^<\//) { depth--; continue }
        depth++
        if (tag=="<version>" && depth==2 && !found) {
          t=rest; sub(/<.*/,"",t)
          if (t==old) { p=index(line,"<version>" old "</version>"); if (p>0) { line=substr(line,1,p-1) "<version>" new "</version>" substr(line,p+length("<version>" old "</version>")); found=1 } }
        } }
      print line }' "$1" > "$tmp"
  cat "$tmp" > "$1"; rm -f "$tmp"
}

# Quoted string literal assigned to a key (Ruby/Python style). KEYRE is a Perl
# regex with no capture groups.
lit_get() { # file keyre
  KEYRE="$2" perl -ne 'if (/$ENV{KEYRE}\s*=\s*([\x27"])([^\x27"]+)\1/) { print "$2\n"; exit }' -- "$1"
}
lit_set() { # file keyre old new   (first occurrence only)
  KEYRE="$2" OLDV="$3" NEWV="$4" perl -pi -e 'BEGIN{$k=$ENV{KEYRE};$o=$ENV{OLDV};$n=$ENV{NEWV}} if(!$d && s/($k\s*=\s*[\x27"])\Q$o\E([\x27"])/$1$n$2/){$d=1}' -- "$1"
}

# ======================================================== current version ===
ver=""; why=""; ver_file=""; tag_derived=""; tag_prefix=""
rb_vfile=""; gomod_path=""

set_why() { why="$*"; }

read_version() {
  ver=""; why=""; tag_derived=""; tag_prefix=""; rb_vfile=""
  ver_file="$manifest"
  local lit name cand tag
  case "$proj_type" in
    r)
      ver="$(grep -m1 '^Version:' "$manifest" \
        | sed -E 's/^Version:[[:space:]]*//; s/[[:space:]]*$//')" || true ;;
    rust)
      ver="$(toml_table_value "$manifest" "[package]" version)"
      if [ -z "$ver" ] && grep -Eq \
          -e '^version\.workspace[[:space:]]*=' \
          -e '^version[[:space:]]*=[[:space:]]*\{[[:space:]]*workspace' \
          "$manifest"; then
        set_why "version is inherited from the workspace" \
          "(version.workspace = true); bump the workspace root manifest" \
          "with --manifest=<root>/Cargo.toml"
      fi ;;
    node)
      ver="$(json_top_value "$manifest")"
      if [ -z "$ver" ]; then
        set_why "no top-level \"version\" key found in $manifest" \
          "(private package, or JSON not one-key-per-line)"
      fi ;;
    python)
      ver="$(toml_table_value "$manifest" "[project] [tool.poetry]" version)"
      if [ -z "$ver" ]; then
        if grep -Eq -e 'dynamic[[:space:]]*=.*"version"' \
            -e '^\[tool\.hatch\.version\]' \
            -e '^\[tool\.setuptools\.dynamic\]' \
            -e '^\[tool\.setuptools_scm\]' \
            -e '^\[tool\.pdm\.version\]' "$manifest"; then
          set_why "the version is dynamic (build backend or VCS tag" \
            "supplies it); point --manifest= at the file that holds it," \
            "or tag the release yourself"
        else
          set_why "no static version in $manifest ([project]/[tool.poetry]);" \
            "if metadata lives in setup.cfg re-run with" \
            "--type=python-setuptools"
        fi
      fi ;;
    python-setuptools)
      if [ "$manifest" = "setup.py" ]; then
        ver="$(lit_get setup.py '(?<![A-Za-z_])version')"
      else
        ver="$(ini_value "$manifest" "[metadata]" version)"
        case "$ver" in
          attr:*|file:*)
            set_why "setup.cfg version is dynamic ($ver); point --manifest=" \
              "at the file that holds it"
            ver="" ;;
        esac
      fi
      if [ -z "$ver" ] && [ -z "$why" ]; then
        set_why "no static version found in $manifest"
      fi ;;
    ruby)
      name="$(basename "$manifest" .gemspec)"
      for cand in "lib/${name//-//}/version.rb" "lib/$name/version.rb"; do
        if [ -f "$cand" ]; then rb_vfile="$cand"; break; fi
      done
      lit="$(lit_get "$manifest" '[.]version')"
      if [ -n "$lit" ]; then
        ver="$lit"
      elif [ -n "$rb_vfile" ]; then
        ver="$(lit_get "$rb_vfile" '(?<![A-Za-z_])VERSION')"
        ver_file="$rb_vfile"
      fi
      if [ -z "$ver" ]; then
        set_why "no literal version in $manifest, and no lib/<gem>/version.rb" \
          "with VERSION = \"...\""
      fi ;;
    php)
      ver="$(json_top_value "$manifest")"
      if [ -z "$ver" ]; then
        tag_derived=1
        tag="$(git describe --tags --abbrev=0 --match '[0-9]*' \
          --match 'v[0-9]*' 2>/dev/null)" || true
        case "$tag" in
          v*) tag_prefix="v"; ver="${tag#v}" ;;
          *) ver="$tag" ;;
        esac
        if [ -z "$ver" ]; then
          set_why "composer.json has no \"version\" (Composer derives it from" \
            "VCS tags) and no version tag is reachable from HEAD"
        fi
      fi ;;
    go)
      [ "$manifest" = "go.mod" ] \
        || die 3 "go: only a root go.mod is supported (multi-module repos" \
                 "use subdirectory tag prefixes)"
      tag_derived=1
      ver="$(git describe --tags --abbrev=0 --match 'v[0-9]*' \
        2>/dev/null)" || true
      gomod_path="$(awk '/^module[[:space:]]/{print $2; exit}' go.mod \
        | tr -d '"')"
      if [ -z "$ver" ]; then
        set_why "no v* git tag reachable from HEAD; a Go module's version is" \
          "its tag (first release: pass an explicit version to apply)"
      fi ;;
    maven)
      ver="$(pom_value "$manifest")"
      if grep -q '<modules>' "$manifest"; then
        set_why "multi-module POM: children inherit or reference this" \
          "version; use 'mvn versions:set -DnewVersion=<new>' instead"
      elif [ -z "$ver" ]; then
        set_why "no project-level <version> in $manifest"
      else
        case "$ver" in
          *'${'*) set_why "version uses a property ($ver);" \
                    "edit the property by hand" ;;
        esac
      fi ;;
    generic)
      ver="$(head -1 "$manifest" | tr -d '[:space:]')" || true ;;
  esac
}

# ============================================================== schemes ====
# next_<scheme> <version> <kind>   -> prints new version (rc 0)
#                                  -> or a reason: rc 2 = kind not applicable,
#                                     rc 3 = version unsupported by this scheme.
# kind "check" only validates.
kinds_for() {
  case "$1" in
    semver|composer|rubygems|gomod)
      echo "patch minor major prerelease release" ;;
    pep440) echo "patch minor major pre dev release" ;;
    rver) echo "patch minor major dev" ;;
    maven) echo "patch minor major snapshot release" ;;
  esac
}

NUM='(0|[1-9][0-9]*)'
RE_SEMVER="^$NUM\\.$NUM\\.$NUM(-([0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*))?\$"

next_semver() {
  local v="$1" k="$2" M m p pre
  case "$v" in
    *+*) echo "build metadata (+...) is not supported;" \
              "pass an explicit version without it"
         return 3 ;;
  esac
  [[ $v =~ $RE_SEMVER ]] \
    || { echo "'$v' is not canonical SemVer X.Y.Z[-prerelease]"; return 3; }
  M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; p="${BASH_REMATCH[3]}"
  pre="${BASH_REMATCH[5]}"
  case "$k" in
    check) echo "$v" ;;
    patch|minor|major)
      if [ -n "$pre" ]; then
        echo "current version is a pre-release; use 'release' (to $M.$m.$p)" \
          "or 'prerelease', or pass an explicit version"
        return 2
      fi
      case "$k" in
        patch) echo "$M.$m.$((p+1))" ;;
        minor) echo "$M.$((m+1)).0" ;;
        major) echo "$((M+1)).0.0" ;;
      esac ;;
    prerelease)
      if [ -z "$pre" ]; then
        echo "not a pre-release; start one by passing an explicit version" \
          "(e.g. $M.$m.$((p+1))-rc.1)"
        return 2
      fi
      if [[ $pre =~ ^(.+)\.([0-9]+)$ ]]; then
        echo "$M.$m.$p-${BASH_REMATCH[1]}.$((10#${BASH_REMATCH[2]}+1))"
      else
        echo "pre-release '$pre' has no trailing numeric identifier (id.N)"
        return 2
      fi ;;
    release)
      if [ -z "$pre" ]; then echo "already a release"; return 2; fi
      echo "$M.$m.$p" ;;
    *) echo "unknown kind '$k'"; return 2 ;;
  esac
}

RE_PEP440="^(([0-9]+)!)?$NUM\\.$NUM\\.$NUM((a|b|rc)$NUM)?"
RE_PEP440="$RE_PEP440(\\.post$NUM)?(\\.dev$NUM)?\$"

# Best-effort normalized spelling, printed only if it is canonical.
pep440_hint() {
  local h
  h="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E '
    s/^v//
    s/([0-9])[-_.]?(alpha|a)[-_.]?([0-9]*)/\1a\3/
    s/([0-9])[-_.]?(beta|b)[-_.]?([0-9]*)/\1b\3/
    s/([0-9])[-_.]?(preview|pre|rc|c)[-_.]?([0-9]+)/\1rc\3/
    s/[-_.]?dev[-_.]?([0-9]+)/.dev\1/
    s/[-_.]?post[-_.]?([0-9]+)/.post\1/')"
  if [[ $h =~ $RE_PEP440 ]]; then echo "$h"; fi
}

next_pep440() {
  local v="$1" k="$2" ep M m p pk pn pre post dev h
  case "$v" in
    *+*) echo "local version labels (+...) are not allowed in published" \
              "releases (PEP 440); not supported"
         return 3 ;;
  esac
  if ! [[ $v =~ $RE_PEP440 ]]; then
    h="$(pep440_hint "$v")"
    if [ -n "$h" ] && [ "$h" != "$v" ]; then
      echo "'$v' is valid-looking but not PEP 440 normalized; the normalized" \
        "spelling is '$h'. Normalize it first (pre-releases are aN/bN/rcN" \
        "with no separator, e.g. 1.2.0rc1, not 1.2.0-rc.1)"
    else
      echo "'$v' is not a supported PEP 440 version" \
        "(need N.N.N[aN|bN|rcN][.postN][.devN], optional epoch 'N!')"
    fi
    return 3
  fi
  ep="${BASH_REMATCH[1]}"; M="${BASH_REMATCH[3]}"; m="${BASH_REMATCH[4]}"
  p="${BASH_REMATCH[5]}"
  pre="${BASH_REMATCH[6]}"; pk="${BASH_REMATCH[7]}"; pn="${BASH_REMATCH[8]}"
  post="${BASH_REMATCH[9]}"; dev="${BASH_REMATCH[11]}"
  local dn="${BASH_REMATCH[12]}"
  case "$k" in
    check) echo "$v" ;;
    patch|minor|major)
      if [ -n "$pre" ] || [ -n "$dev" ]; then
        echo "current version is a pre/dev release; use 'release'" \
          "(to $ep$M.$m.$p), 'pre' or 'dev', or pass an explicit version"
        return 2
      fi
      case "$k" in
        patch) echo "$ep$M.$m.$((p+1))" ;;
        minor) echo "$ep$M.$((m+1)).0" ;;
        major) echo "$ep$((M+1)).0.0" ;;
      esac ;;
    pre)
      if [ -z "$pre" ]; then
        echo "not an a/b/rc pre-release; start one by passing an explicit" \
          "version (e.g. $ep$M.$m.$((p+1))rc1)"
        return 2
      fi
      if [ -n "$dev" ] || [ -n "$post" ]; then
        echo "has a .dev/.post segment; bump that first or pass an" \
          "explicit version"
        return 2
      fi
      echo "$ep$M.$m.$p$pk$((10#$pn+1))" ;;
    dev)
      if [ -z "$dev" ]; then
        echo "no .devN segment; start one by passing an explicit version" \
          "(e.g. $ep$M.$m.$p.dev0)"
        return 2
      fi
      echo "$ep$M.$m.$p$pre$post.dev$((10#$dn+1))" ;;
    release)
      if [ -z "$pre" ] && [ -z "$dev" ]; then
        echo "already a final release"; return 2
      fi
      if [ -n "$post" ]; then
        echo "post-release: dropping it would go backwards;" \
          "pass an explicit version"
        return 2
      fi
      echo "$ep$M.$m.$p" ;;
    *) echo "unknown kind '$k'"; return 2 ;;
  esac
}

RE_RVER="^$NUM\\.$NUM\\.$NUM(\\.([0-9]+))?\$"

next_rver() { # mirrors desc::bump_version() / usethis::use_version()
  local v="$1" k="$2" M m p d
  case "$v" in
    *-*) echo "'$v' uses R's '-' separator (legal in R, but not supported" \
              "here); use the dotted X.Y.Z[.9000] form"
         return 3 ;;
  esac
  [[ $v =~ $RE_RVER ]] || {
    echo "'$v' is not X.Y.Z or X.Y.Z.<dev> (R release versions are" \
      "three-part; two-part versions are not supported)"
    return 3
  }
  M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; p="${BASH_REMATCH[3]}"
  d="${BASH_REMATCH[5]}"
  case "$k" in
    check) echo "$v" ;;
    patch) echo "$M.$m.$((p+1))" ;;
    minor) echo "$M.$((m+1)).0" ;;
    major) echo "$((M+1)).0.0" ;;
    dev)
      if [ -z "$d" ]; then echo "$M.$m.$p.9000"
      else echo "$M.$m.$p.$((10#$d+1))"; fi ;;
    *) echo "unknown kind '$k'"; return 2 ;;
  esac
}

RE_RUBYGEMS="^$NUM\\.$NUM\\.$NUM(\\.([A-Za-z]+)(([0-9]+)|\\.([0-9]+))?)?\$"

next_rubygems() {
  local v="$1" k="$2" M m p pre letters att dot
  case "$v" in
    *-*) echo "'$v': RubyGems rewrites '-' to '.pre.' ('1.2.3-rc1' is" \
              "'1.2.3.pre.rc1', not SemVer's pre-release); write the dotted" \
              "form, e.g. 1.2.3.rc1"
         return 3 ;;
  esac
  [[ $v =~ $RE_RUBYGEMS ]] || {
    echo "'$v' is not N.N.N[.<letters>[N]] (four numeric segments are not" \
      "supported)"
    return 3
  }
  M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; p="${BASH_REMATCH[3]}"
  pre="${BASH_REMATCH[4]}"; letters="${BASH_REMATCH[5]}"
  att="${BASH_REMATCH[7]}"; dot="${BASH_REMATCH[8]}"
  case "$k" in
    check) echo "$v" ;;
    patch|minor|major)
      if [ -n "$pre" ]; then
        echo "current version is a pre-release (a letter segment);" \
          "use 'release' (to $M.$m.$p) or 'prerelease', or pass an" \
          "explicit version"
        return 2
      fi
      case "$k" in
        patch) echo "$M.$m.$((p+1))" ;;
        minor) echo "$M.$((m+1)).0" ;;
        major) echo "$((M+1)).0.0" ;;
      esac ;;
    prerelease)
      if [ -z "$pre" ]; then
        echo "not a pre-release; start one by passing an explicit version" \
          "(e.g. $M.$m.$((p+1)).rc1)"
        return 2
      fi
      if [ -n "$att" ]; then echo "$M.$m.$p.$letters$((10#$att+1))"
      elif [ -n "$dot" ]; then echo "$M.$m.$p.$letters.$((10#$dot+1))"
      else
        echo "pre-release '$letters' has no number to increment; pass an" \
          "explicit version (e.g. $M.$m.$p.${letters}1)"
        return 2
      fi ;;
    release)
      if [ -z "$pre" ]; then echo "already a release"; return 2; fi
      echo "$M.$m.$p" ;;
    *) echo "unknown kind '$k'"; return 2 ;;
  esac
}

RE_GOPSEUDO='-[0-9]{14}-[0-9a-f]{12}$'
next_gomod() {
  local v="$1" k="$2" r rc=0
  case "$v" in
    v*) ;;
    *) echo "Go module versions start with 'v' (got '$v')"; return 3 ;;
  esac
  case "$v" in
    *+*) echo "'+incompatible'/build metadata is not supported"; return 3 ;;
  esac
  if [[ $v =~ $RE_GOPSEUDO ]]; then
    echo "'$v' is a pseudo-version, not a tagged release"; return 3
  fi
  r="$(next_semver "${v#v}" "$k")" || rc=$?
  if [ "$rc" -eq 0 ]; then echo "v$r"; else echo "$r"; return "$rc"; fi
}

RE_MAVEN="^$NUM\\.$NUM\\.$NUM(-SNAPSHOT)?\$"
next_maven() {
  local v="$1" k="$2" M m p snap
  [[ $v =~ $RE_MAVEN ]] || {
    echo "'$v' is not N.N.N[-SNAPSHOT] (other qualifiers are not supported)"
    return 3
  }
  M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; p="${BASH_REMATCH[3]}"
  snap="${BASH_REMATCH[4]}"
  case "$k" in
    check) echo "$v" ;;
    patch|minor|major)
      if [ -n "$snap" ]; then
        echo "current version is a -SNAPSHOT; use 'release' (to $M.$m.$p)" \
          "or pass an explicit version"
        return 2
      fi
      case "$k" in
        patch) echo "$M.$m.$((p+1))" ;;
        minor) echo "$M.$((m+1)).0" ;;
        major) echo "$((M+1)).0.0" ;;
      esac ;;
    snapshot)
      if [ -n "$snap" ]; then echo "already a -SNAPSHOT"; return 2; fi
      echo "$M.$m.$((p+1))-SNAPSHOT" ;;
    release)
      if [ -z "$snap" ]; then echo "already a release"; return 2; fi
      echo "$M.$m.$p" ;;
    *) echo "unknown kind '$k'"; return 2 ;;
  esac
}

next_composer() { # SemVer, optional leading v (tag style)
  local v="$1" k="$2" pfx="" r rc=0
  case "$v" in v*) pfx="v"; v="${v#v}" ;; esac
  r="$(next_semver "$v" "$k")" || rc=$?
  if [ "$rc" -eq 0 ]; then echo "$pfx$r"; else echo "$r"; return "$rc"; fi
}

scheme_next() { "next_$scheme" "$@"; }

# ======================================================= other locations ====
# One line per location: file|version|kind   (kind e = editable, l = lockfile)
secondary_locations() {
  local f v name pkg_name
  case "$proj_type" in
    ruby)
      if [ -n "$rb_vfile" ] && [ "$ver_file" != "$rb_vfile" ]; then
        v="$(lit_get "$rb_vfile" '(?<![A-Za-z_])VERSION')"
        echo "$rb_vfile|$v|e"
      fi ;;
    python|python-setuptools)
      { git ls-files -- '*__init__.py' '*__about__.py' '*version.py' \
          2>/dev/null \
          | grep -Ev '(^|/)(tests?|docs?|examples?|build)/' || true; } \
        | while IFS= read -r f; do
            [ "$f" = "$manifest" ] && continue
            v="$(lit_get "$f" '^__version__')"
            if [ -n "$v" ]; then echo "$f|$v|e"; fi
          done ;;
    node)
      for f in package-lock.json npm-shrinkwrap.json; do
        if [ -f "$f" ]; then echo "$f|$(json_top_value "$f")|l"; fi
      done ;;
    rust)
      if [ -f Cargo.lock ]; then
        pkg_name="$(toml_table_value Cargo.toml "[package]" name)"
        if [ -n "$pkg_name" ]; then
          v="$(awk -v name="$pkg_name" '
            /^\[\[package\]\]/{ if (inblock && nm==name && !printed) { print ver; printed=1; exit } inblock=1; nm=""; ver=""; next }
            inblock && /^name[[:space:]]*=/{ x=$0; sub(/^[^"]*"/,"",x); sub(/".*/,"",x); nm=x }
            inblock && /^version[[:space:]]*=/{ x=$0; sub(/^[^"]*"/,"",x); sub(/".*/,"",x); ver=x }
            END { if (!printed && inblock && nm==name) print ver }' Cargo.lock)"
          echo "Cargo.lock (package \"$pkg_name\")|$v|l"
        fi
      fi ;;
  esac
  return 0
}

sync_report=""; sync_bad=0
report() { sync_report="$sync_report$*"$'\n'; }
# check_sync <expected> <lock_blocks 1|0>
check_sync() {
  local expected="$1" lock_blocks="$2" secs line f rest v kind maj want have
  sync_report=""; sync_bad=0
  if [ -z "$expected" ]; then return 0; fi
  secs="$(secondary_locations)" || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%%|*}"; rest="${line#*|}"; v="${rest%%|*}"; kind="${rest#*|}"
    if [ -z "$v" ]; then
      report "UNPARSEABLE: found $f but could not read a version from it"
      sync_bad=$((sync_bad+1))
    elif [ "$v" != "$expected" ]; then
      if [ "$kind" = l ] && [ "$lock_blocks" = 0 ]; then
        report "NOTE: $f still says \"$v\" -- regenerate it with your" \
          "package manager"
      else
        report "MISMATCH: $ver_file says \"$expected\" but $f says \"$v\""
        sync_bad=$((sync_bad+1))
      fi
    else
      report "OK: $f agrees ($v)"
    fi
  done <<< "$secs"
  if [ "$proj_type" = go ] && [ -n "$gomod_path" ] && [ -n "$expected" ] \
      && [[ $expected != *+* ]]; then
    maj="${expected#v}"; maj="${maj%%.*}"
    want=""; if [ "$maj" -ge 2 ] 2>/dev/null; then want="/v$maj"; fi
    have=""
    if [[ $gomod_path =~ /v([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -ge 2 ]; then
      have="/v${BASH_REMATCH[1]}"
    fi
    case "$gomod_path" in gopkg.in/*) want="$have" ;; esac
    if [ "$want" != "$have" ]; then
      report "MISMATCH: go.mod module path \"$gomod_path\" has suffix" \
        "\"${have:-none}\" but major version ${maj} requires" \
        "\"${want:-none}\""
      sync_bad=$((sync_bad+1))
    fi
  fi
  return 0
}

# ============================================================ occurrences ====
excl=(); lockspec=()
build_excludes() {
  local n
  excl=(); lockspec=()
  for n in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml \
           Cargo.lock poetry.lock Gemfile.lock composer.lock go.sum; do
    excl+=(":(exclude,glob)**/$n"); lockspec+=(":(glob)**/$n")
  done
  for n in NEWS.md CHANGELOG.md CHANGES.md HISTORY.md '*.tar.gz' '*.whl' \
           '*.gem'; do
    excl+=(":(exclude,glob)**/$n")
  done
  for n in node_modules dist build target vendor __pycache__ '*.egg-info' \
           .venv venv .tox; do
    excl+=(":(exclude,glob)**/$n/**")
  done
  if [ "$proj_type" = r ]; then excl+=(':(exclude,glob)man/**'); fi
  return 0
}

# file:line:text for tracked text files containing $1 as a whole version token
# (not inside 11.2.0, 1.2.03, 1.2.0.9000, 1.2.0-rc1; a leading v is fine).
occurrences() { # version, newline-separated files to skip
  { git grep -nIF -e "$1" -- . "${excl[@]}" 2>/dev/null || true; } \
    | OLDV="$1" SKIP="$2" perl -ne '
        BEGIN { $o=$ENV{OLDV}; %s=map { $_=>1 } split /\n/, $ENV{SKIP} }
        if (/^([^:]+):(\d+):(.*)$/) {
          next if $s{$1};
          if ($3 =~ /(?:(?<![0-9A-Za-z_.+-])|(?<=\bv))\Q$o\E(?![0-9A-Za-z_+-]|\.[0-9A-Za-z])/) { print substr($_,0,200); print "\n" if length($_)>200; }
        }'
}

skip_list() { # primary + editable secondaries
  local line
  echo "$ver_file"; echo "$manifest"
  secondary_locations | while IFS= read -r line; do echo "${line%%|*}"; done
}

# ================================================================ API diff ====
api_diff() {
  local last_commit="$1" f="" cand
  local pub_re='^[[:space:]]*pub (fn|struct|enum|trait|const|mod|type) '
  case "$proj_type" in
    r)
      if [ -n "$last_commit" ] \
          && git cat-file -e "${last_commit}:NAMESPACE" 2>/dev/null; then
        diff <(git show "${last_commit}:NAMESPACE" | grep '^export(' | sort) \
             <(grep '^export(' NAMESPACE 2>/dev/null | sort) \
          && echo "(no export changes)" || true
      else
        echo "(NAMESPACE absent at the comparison point -- treating all" \
          "current exports as new)"
        grep '^export(' NAMESPACE 2>/dev/null || echo "(no NAMESPACE file)"
      fi ;;
    rust)
      [ -f src/lib.rs ] && f=src/lib.rs
      if [ -z "$f" ]; then
        echo "(no src/lib.rs found -- skipping pub-item heuristic)"
      elif [ -n "$last_commit" ] \
          && git cat-file -e "${last_commit}:${f}" 2>/dev/null; then
        diff <(git show "${last_commit}:${f}" | grep -E "$pub_re" | sort) \
             <(grep -E "$pub_re" "$f" | sort) \
          && echo "(no pub-item changes in $f)" || true
        echo "(heuristic: top-level 'pub' items in $f only --" \
          "misses re-exports and nested modules)"
      else
        echo "($f absent at the comparison point --" \
          "treating all current pub items as new)"
        grep -E "$pub_re" "$f" || true
      fi ;;
    node)
      for cand in src/index.ts src/index.js index.ts index.js; do
        if [ -f "$cand" ]; then f="$cand"; break; fi
      done
      if [ -z "$f" ]; then
        echo "(no index.ts/js entry point found -- skipping export heuristic)"
      elif [ -n "$last_commit" ] \
          && git cat-file -e "${last_commit}:${f}" 2>/dev/null; then
        diff <(git show "${last_commit}:${f}" | grep -E '^export ' | sort) \
             <(grep -E '^export ' "$f" | sort) \
          && echo "(no top-level export changes in $f)" || true
        echo "(heuristic: top-level 'export' statements in $f only --" \
          "misses re-exports via barrel files)"
      else
        echo "($f absent at the comparison point --" \
          "treating all current exports as new)"
        grep -E '^export ' "$f" || true
      fi ;;
    python|python-setuptools)
      f="$(git ls-files -- '*__init__.py' | xargs grep -l '__all__' \
        2>/dev/null | head -1 || true)"
      if [ -z "$f" ]; then
        echo "(no __init__.py with __all__ found -- skipping export heuristic)"
      elif [ -n "$last_commit" ] \
          && git cat-file -e "${last_commit}:${f}" 2>/dev/null; then
        diff <(git show "${last_commit}:${f}" | grep -A50 '^__all__' \
                 | sed '/^\]/q') \
             <(grep -A50 '^__all__' "$f" | sed '/^\]/q') \
          && echo "(no __all__ changes in $f)" || true
        echo "(heuristic: __all__ block in $f only)"
      else
        echo "($f absent at the comparison point --" \
          "treating current __all__ as new)"
      fi ;;
    *)
      echo "(no automated public-API diff for project type '$proj_type' --" \
        "read the commit log yourself for breaking/additive changes)" ;;
  esac
}

version_line_pattern() {
  case "$proj_type" in
    r) echo '^Version:' ;;
    rust|python) echo '^version[[:space:]]*=' ;;
    node|php) echo '"version"[[:space:]]*:' ;;
    python-setuptools) echo 'version[[:space:]]*=' ;;
    ruby) echo 'VERSION[[:space:]]*=|[.]version[[:space:]]*=' ;;
    maven) echo '<version>' ;;
    *) echo '.' ;;
  esac
}

# ================================================================ writers ====
write_primary() { # old new
  local o="$1" n="$2"
  case "$proj_type" in
    r) OLDV="$o" NEWV="$n" perl -pi -e 'BEGIN{$o=$ENV{OLDV};$n=$ENV{NEWV}} if(!$d && s/^(Version:\s*)\Q$o\E(\s*)$/$1$n$2/){$d=1}' -- "$manifest" ;;
    rust) toml_table_set "$manifest" "[package]" version "$o" "$n" ;;
    node) json_top_set "$manifest" "$o" "$n" ;;
    php)
      if [ -z "$tag_derived" ]; then json_top_set "$manifest" "$o" "$n"; fi ;;
    python)
      toml_table_set "$manifest" "[project] [tool.poetry]" version "$o" "$n" ;;
    python-setuptools)
      if [ "$manifest" = "setup.py" ]; then
        lit_set setup.py '(?<![A-Za-z_])version' "$o" "$n"
      else ini_set "$manifest" "[metadata]" version "$o" "$n"; fi ;;
    ruby)
      if [ "$ver_file" = "$manifest" ]; then
        lit_set "$ver_file" '[.]version' "$o" "$n"
      else lit_set "$ver_file" '(?<![A-Za-z_])VERSION' "$o" "$n"; fi ;;
    maven) pom_set "$manifest" "$o" "$n" ;;
    generic) printf '%s\n' "$n" > "$manifest" ;;
    # version lives in a git tag; module-path rewrite handled separately
    go) : ;;
  esac
}

write_secondary() { # file old new
  case "$proj_type" in
    ruby) lit_set "$1" '(?<![A-Za-z_])VERSION' "$2" "$3" ;;
    python|python-setuptools) lit_set "$1" '^__version__' "$2" "$3" ;;
  esac
}

is_bad_also_target() { # path -> reason on stdout if not allowed
  local f="$1"
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 \
    || { echo "not a tracked file"; return 0; }
  [ -L "$f" ] && { echo "is a symlink"; return 0; }
  git ls-files -- . "${excl[@]}" | grep -qxF "$f" \
    || { echo "is a changelog/lockfile/build path (excluded by design)"
         return 0; }
  git grep -qI -e . -- "$f" 2>/dev/null \
    || { echo "is binary or empty"; return 0; }
  return 0
}

also_replace() { # file old new
  OLDV="$2" NEWV="$3" perl -pi -e '
    BEGIN { $o=$ENV{OLDV}; $n=$ENV{NEWV} }
    s/(?:(?<![0-9A-Za-z_.+-])|(?<=\bv))\Q$o\E(?![0-9A-Za-z_+-]|\.[0-9A-Za-z])/$n/g' -- "$1"
}

go_new_path() { # newver -> module path for that major
  local base="$gomod_path" maj
  if [[ $base =~ ^(.*)/v[0-9]+$ ]]; then base="${BASH_REMATCH[1]}"; fi
  maj="${1#v}"; maj="${maj%%.*}"
  case "$gomod_path" in gopkg.in/*) echo "$gomod_path"; return 0 ;; esac
  if [ "$maj" -ge 2 ]; then echo "$base/v$maj"; else echo "$base"; fi
}

go_files_with_path() {
  git grep -lIF -e "\"$gomod_path" -- '*.go' ':(exclude,glob)**/vendor/**' \
    2>/dev/null || true
}

go_rewrite() { # oldpath newpath
  OLDP="$1" NEWP="$2" perl -pi -e 'BEGIN{$o=$ENV{OLDP};$n=$ENV{NEWP}} s{^(module\s+)\Q$o\E(\s*)$}{$1$n$2}' go.mod
  local f
  go_files_with_path | while IFS= read -r f; do
    OLDP="$1" NEWP="$2" perl -pi -e 'BEGIN{$o=$ENV{OLDP};$n=$ENV{NEWP}} s{"\Q$o\E((?:/[^"]*)?)"}{"$n$1"}g' -- "$f"
  done
}

# ================================================================ commands ====
dirty_warn() {
  if git status --porcelain --untracked-files=no | grep -q .; then
    echo "WARNING: the working tree has uncommitted changes; they will be" \
      "mixed into 'git diff' after the bump."
  fi
}

case "$cmd" in
# ------------------------------------------------------------------- scan ----
scan)
  detect; build_excludes; read_version
  scan_rc=0
  echo "Detected project type: $proj_type" \
    " (manifest: $manifest${ver_file:+; version read from $ver_file})"
  echo "Scheme: $scheme  (format and bump rules: references/conventions.md)"
  oth="$(other_manifests)"
  if [ -n "$oth" ]; then
    echo "NOTE: also found:$oth -- if this is the wrong ecosystem, re-run" \
      "with --type= / --manifest="
  fi
  tagnote="  (derived from a git tag; this skill writes no tag)"
  echo "Current version: ${ver:-<none>}${tag_derived:+$tagnote}"
  if [ -n "$why" ]; then echo "UNSUPPORTED: $why"; scan_rc=3; fi
  if [ -n "$ver" ] && [ -z "$why" ]; then
    rc=0; out="$(scheme_next "$ver" check)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "UNSUPPORTED: $out"
      echo "STOP: do not guess how to bump this; ask the user for the exact" \
        "new version or fix the format first."
      scan_rc=3
    else
      echo "Bump candidates (computed by the script; do not recompute by hand):"
      for k in $(kinds_for "$scheme"); do
        rc=0; out="$(scheme_next "$ver" "$k")" || rc=$?
        mark=""
        case "$k" in
          major|release) mark="   [user-only: never propose, ask]" ;;
        esac
        if [ "$rc" -eq 0 ]; then echo "  $k -> $out$mark"
        else echo "  $k -> n/a ($out)"; fi
      done
      if [ "$proj_type" = rust ] && [[ $ver =~ ^0\. ]]; then
        echo "NOTE (Cargo, 0.y.z): a breaking change bumps y (use 'minor');" \
          "additive/fix changes bump z (use 'patch'); 0.0.z: every change" \
          "is breaking."
      fi
    fi
  fi
  echo

  if [ "$tag_derived" = 1 ] && [ -n "$ver" ]; then
    tagname="$ver"; [ "$proj_type" = php ] && tagname="$tag_prefix$ver"
    last_bump_commit="$(git rev-list -n1 "$tagname" 2>/dev/null)" || true
    echo "--- Commit of the latest version tag ($tagname) ---"
  else
    pattern="$(version_line_pattern)"
    last_bump_commit="$(git log -G "$pattern" --format='%H' -- "$ver_file" \
      | head -1)" || true
    echo "--- Last commit that changed the version field in $ver_file ---"
  fi
  if [ -z "${last_bump_commit:-}" ]; then
    echo "(none found -- version has never been bumped;" \
      "using full repo history)"
    range="$(git rev-list --max-parents=0 HEAD | tail -1)..HEAD"
  else
    echo "$last_bump_commit"; range="${last_bump_commit}..HEAD"
  fi
  echo
  echo "--- Commits since last bump ($range) ---"
  git log --oneline "$range" 2>/dev/null || echo "(no commits in range)"
  echo
  echo "--- Public-API diff since last bump (signal for patch vs. minor) ---"
  api_diff "${last_bump_commit:-}"
  echo

  echo "--- Other tracked occurrences of \"${ver:-?}\" (NOT changed by apply" \
    "unless named with --also) ---"
  if [ -n "$ver" ]; then
    hits="$(occurrences "$ver" "$(skip_list)")"
    if [ -z "$hits" ]; then echo "(none)"; else
      printf '%s\n' "$hits" | awk 'NR<=40'
      n_hits="$(printf '%s\n' "$hits" | awk 'END{print NR}')"
      if [ "$n_hits" -gt 40 ]; then echo "... and $((n_hits-40)) more"; fi
      echo "(dependency pins of other packages, dates, fixtures and sample" \
        "data show up here too: review each line before adding its file" \
        "with --also=<path>)"
    fi
  else
    echo "(skipped -- no version parsed)"
  fi
  echo

  found_changelog=""
  for f in NEWS.md CHANGELOG.md CHANGES.md HISTORY.md; do
    if [ -f "$f" ]; then
      echo "NOTE: $f exists -- never rewrite its past version headers;" \
        "apply excludes it."
      found_changelog=1
    fi
  done
  if [ -z "$found_changelog" ]; then
    cl_names="NEWS.md/CHANGELOG.md/CHANGES.md/HISTORY.md"
    echo "NOTE: no changelog file ($cl_names) yet -- ask the user which to" \
      "create before recording this change."
  fi
  echo

  echo "--- Out-of-sync check (secondary version locations) ---"
  check_sync "$ver" 1
  if [ -z "$sync_report" ]; then
    echo "(no conventional secondary version location for type" \
      "'$proj_type', or none found in this repo)"
  else printf '%s' "$sync_report"; fi
  if [ "$sync_bad" -gt 0 ]; then
    echo "STOP: $ver_file is the source of truth here -- confirm with the" \
      "user which value is correct before bumping anything. 'apply' refuses" \
      "to run until this is resolved (or overridden with --force)."
    if [ "$scan_rc" -eq 0 ]; then scan_rc=2; fi
  fi
  exit "$scan_rc"
  ;;

# ------------------------------------------------------------------ apply ----
apply)
  old="${1:?usage: version_bump.sh apply <old> <new> [flags]}"
  new="${2:?usage: version_bump.sh apply <old> <new> [flags]}"
  detect; build_excludes; read_version
  echo "Project type: $proj_type   scheme: $scheme"

  if [ -n "$why" ]; then die 3 "UNSUPPORTED: $why"; fi
  if [ -z "$ver" ]; then
    die 3 "UNSUPPORTED: could not read a version from $ver_file"
  fi
  if [ "$old" != "$ver" ]; then
    die 2 "ABORTING: <old> \"$old\" is not the current version \"$ver\"" \
      "($ver_file). Nothing was changed."
  fi
  rc=0; out="$(scheme_next "$old" check)" || rc=$?
  if [ "$rc" -ne 0 ]; then die 3 "UNSUPPORTED current version: $out"; fi
  rc=0; out="$(scheme_next "$new" check)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die 3 "INVALID new version for scheme $scheme: $out"
  fi
  if [ "$new" = "$old" ]; then
    die 2 "ABORTING: new version equals the old one."
  fi

  check_sync "$old" 1
  if [ "$sync_bad" -gt 0 ]; then
    if [ -z "$force" ]; then
      printf '%s' "$sync_report" >&2
      die 2 "ABORTING: out-of-sync version locations. Resolve the mismatch" \
        "first, or re-run with --force if the user confirmed $ver_file is" \
        "correct and the other location will be fixed separately."
    fi
    echo "WARNING (--force): proceeding despite out-of-sync locations:"
    printf '%s' "$sync_report" | grep -v '^OK' || true
  fi
  dirty_warn

  # ---- plan ----
  edits=()
  if [ -z "$tag_derived" ]; then edits+=("$ver_file"); fi
  sec_edit="$(secondary_locations | awk -F'|' '$3=="e"{print $1}')" || true
  if [ -n "$sec_edit" ]; then
    while IFS= read -r f; do edits+=("$f"); done <<< "$sec_edit"
  fi
  also_files=()
  for f in ${also[@]+"${also[@]}"}; do
    reason="$(is_bad_also_target "$f")"
    if [ -n "$reason" ]; then die 2 "ABORTING: --also=$f $reason."; fi
    also_files+=("$f")
  done

  go_old_path=""; go_new_path_v=""
  if [ "$proj_type" = go ]; then
    go_new_path_v="$(go_new_path "$new")"
    if [ "$go_new_path_v" != "$gomod_path" ]; then go_old_path="$gomod_path"; fi
  fi

  # Refuse symlinks and dash-leading names: writes through `>` follow
  # symlinks, and a name like -Mfoo__init__.py would otherwise be parsed as
  # an option.
  for t in ${edits[@]+"${edits[@]}"} ${also_files[@]+"${also_files[@]}"} \
           $( [ -n "$go_old_path" ] &&
              { echo go.mod; go_files_with_path; } ); do
    case "$t" in -*) die 2 "refusing to write $t: name starts with '-'" ;; esac
    [ -L "$t" ] && die 2 "refusing to write $t: it is a symlink"
  done

  verb="update"; vrw="rewrite"
  if [ -n "$dry" ]; then
    echo "DRY RUN -- nothing will be written."
    verb="would update"; vrw="would rewrite"
  fi
  for f in ${edits[@]+"${edits[@]}"}; do
    echo "$verb: $f   ($old -> $new)"
  done
  for f in ${also_files[@]+"${also_files[@]}"}; do
    echo "$verb: $f   (--also, whole-token matches only)"
    if [ -n "$dry" ]; then
      occurrences "$old" "" | awk -F: -v f="$f" '$1==f' | sed 's/^/    /'
    fi
  done
  if [ -n "$go_old_path" ]; then
    echo "$vrw: go.mod module path  $go_old_path -> $go_new_path_v"
    go_files_with_path | sed "s|^|$vrw: |; s|\$|   (import paths)|"
  fi
  if [ -n "$dry" ]; then exit 0; fi

  # ---- write ----
  if [ -z "$tag_derived" ]; then write_primary "$old" "$new"; fi
  if [ -n "$sec_edit" ]; then
    while IFS= read -r f; do
      write_secondary "$f" "$old" "$new"
    done <<< "$sec_edit"
  fi
  for f in ${also_files[@]+"${also_files[@]}"}; do
    also_replace "$f" "$old" "$new"
  done
  if [ -n "$go_old_path" ]; then go_rewrite "$go_old_path" "$go_new_path_v"; fi

  # ---- post-check ----
  if [ -z "$tag_derived" ]; then
    read_version
    if [ "$ver" != "$new" ]; then
      die 2 "POST-CHECK FAILED: $ver_file now reads \"${ver:-<none>}\"," \
        "expected \"$new\". Files above were modified; inspect with git diff."
    fi
  fi
  locks="$(git grep -lIF -e "$old" -- "${lockspec[@]}" 2>/dev/null || true)"
  if [ -n "$locks" ]; then
    echo
    echo "NOTE: left these lockfiles untouched (regenerate via your package" \
      "manager: npm install, cargo generate-lockfile, poetry lock, bundle" \
      "lock, composer update --lock):"
    echo "$locks"
  fi
  if [ "$tag_derived" = 1 ]; then
    echo
    echo "NOTE: this version is a git tag. No tag was created; the user" \
      "creates ${tag_prefix}${new#v} themselves (Go/Composer tags are the" \
      "release)."
  fi
  echo
  echo "Done. Next: 'verify $old $new', then 'git diff'. No commit or tag" \
    "was made."
  ;;

# ----------------------------------------------------------------- verify ----
verify)
  old="${1:?usage: version_bump.sh verify <old> <new>}"
  new="${2:?usage: version_bump.sh verify <old> <new>}"
  detect; build_excludes; read_version
  bad=0
  if [ -z "$tag_derived" ]; then
    if [ "$ver" = "$new" ]; then echo "OK: $ver_file says \"$new\""
    else
      echo "FAIL: $ver_file says \"${ver:-<none>}\", expected \"$new\""
      bad=1
    fi
  else
    echo "NOTE: version is tag-derived; confirm the tag" \
      "\"${tag_prefix}${new#v}\" yourself (this skill never tags)."
  fi
  check_sync "$new" 0
  printf '%s' "$sync_report"
  if [ "$sync_bad" -gt 0 ]; then bad=1; fi
  echo "--- Remaining whole-token occurrences of \"$old\"" \
    "(excluding changelogs/lockfiles/build dirs) ---"
  hits="$(occurrences "$old" "$(skip_list)")"
  if [ -z "$hits" ]; then echo "(none)"
  else
    printf '%s\n' "$hits" | awk 'NR<=40'
    echo "(review: stale references, or other packages' pins that" \
      "correctly stay)"
  fi
  if [ "$bad" -ne 0 ]; then exit 2; fi
  ;;
esac
