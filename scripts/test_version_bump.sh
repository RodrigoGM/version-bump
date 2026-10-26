#!/usr/bin/env bash
# Self-check for version_bump.sh. Builds throwaway git repos in a temp dir.
#   /bin/bash scripts/test_version_bump.sh      (macOS system bash 3.2 included)
# Exits non-zero if any assertion fails.
S="$(cd "$(dirname "$0")" && pwd)/version_bump.sh"
CONV="$(cd "$(dirname "$0")/.." && pwd)/references/conventions.md"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0; out=""; rc=0

ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }
eq()   {
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi
}
has()  {
  case "$2" in
    *"$3"*) ok ;;
    *) bad "$1: missing [$3] in:"; echo "$2" | sed 's/^/    | /' ;;
  esac
}
hasnt(){
  case "$2" in
    *"$3"*) bad "$1: unexpected [$3] in:"; echo "$2" | sed 's/^/    | /' ;;
    *) ok ;;
  esac
}
run()  { rc=0; out="$(/bin/bash "$S" "$@" 2>&1)" || rc=$?; }
repo() {
  cd "$ROOT" && rm -rf "$1" && mkdir "$1" && cd "$1" && git init -q \
    && git config user.email t@t && git config user.name t
}
commit() { git add -A && git commit -qm "${1:-c}"; }
w() { mkdir -p "$(dirname "$1")"; cat > "$1"; }   # write stdin to file
clean() { [ -z "$(git status --porcelain)" ]; }

# ---------------------------------------------------------------- T1 R ----
repo r
w DESCRIPTION <<'EOF'
Package: pkg
Version: 0.1.0.9000
Imports: dplyr (>= 0.1.0)
EOF
w README.md <<<"Install pkg 0.1.0.9000 from source."
w man/x.Rd <<<"\\title{pkg 0.1.0.9000}"
w pkg/NEWS.md <<<"# pkg 0.1.0.9000"
commit
run scan
has "T1 scan type" "$out" "Scheme: rver"
has "T1 patch" "$out" "patch -> 0.1.1"
has "T1 minor" "$out" "minor -> 0.2.0"
has "T1 dev" "$out" "dev -> 0.1.0.9001"
hasnt "T1 no release kind (usethis has none)" "$out" "release ->"
has "T1 README listed" "$out" "README.md:1:"
hasnt "T1 man excluded" "$out" "man/x.Rd"
hasnt "T1 nested NEWS excluded" "$out" "pkg/NEWS.md"
hasnt "T1 dep pin not a hit (0.1.0 != 0.1.0.9000)" "$out" "Imports"
run apply 0.1.0 0.1.1
eq "T1 wrong old exit" "$rc" 2
clean && ok || bad "T1 wrong old changed files"
run apply 0.1.0.9000 0.1.1-1;     eq "T1 hyphen new rejected" "$rc" 3
run apply 0.1.0.9000 0.1.1 --dry-run
eq "T1 dry-run exit" "$rc" 0
clean && ok || bad "T1 dry-run wrote"
run apply 0.1.0.9000 0.1.1;       eq "T1 apply exit" "$rc" 0
has "T1 Version" "$(cat DESCRIPTION)" "Version: 0.1.1"
has "T1 dplyr pin untouched" "$(cat DESCRIPTION)" "dplyr (>= 0.1.0)"
has "T1 README untouched w/o --also" "$(cat README.md)" "0.1.0.9000"
has "T1 man untouched" "$(cat man/x.Rd)" "0.1.0.9000"
run verify 0.1.0.9000 0.1.1
eq "T1 verify exit" "$rc" 0
has "T1 verify lists straggler" "$out" "README.md"
git checkout -q . && run apply 0.1.0.9000 0.1.1 --also=README.md
eq "T1 --also exit" "$rc" 0
has "T1 README updated via --also" "$(cat README.md)" "Install pkg 0.1.1 from"
run apply 0.1.1 0.1.2 --also=pkg/NEWS.md
eq "T1 --also refuses changelog" "$rc" 2

# ------------------------------------------------------------ T2 Python ----
repo py
w pyproject.toml <<'EOF'
[project]
name = "x"
version = "1.2.0rc1"
dependencies = ["foo>=1.2.0rc1"]
EOF
w x/__init__.py <<<'__version__ = "1.2.0rc1"'
commit
run scan
has "T2 scheme" "$out" "Scheme: pep440"
has "T2 pre" "$out" "pre -> 1.2.0rc2"
has "T2 release" "$out" "release -> 1.2.0   [user-only"
has "T2 patch refused" "$out" "patch -> n/a"
run apply 1.2.0rc1 1.2.0-rc.2
eq "T2 SemVer spelling rejected" "$rc" 3
has "T2 hint" "$out" "1.2.0rc2"
run apply 1.2.0rc1 1.2.0rc2;   eq "T2 apply exit" "$rc" 0
has "T2 pyproject" "$(cat pyproject.toml)" 'version = "1.2.0rc2"'
has "T2 dep pin untouched" "$(cat pyproject.toml)" "foo>=1.2.0rc1"
has "T2 __version__ synced" "$(cat x/__init__.py)" "1.2.0rc2"
echo '__version__ = "9.9.9"' > x/__init__.py; commit
run apply 1.2.0rc2 1.2.0rc3
eq "T2 out-of-sync refused" "$rc" 2
has "T2 mismatch" "$out" "MISMATCH"
run apply 1.2.0rc2 1.2.0rc3 --force; eq "T2 --force proceeds" "$rc" 0
repo py2
w pyproject.toml <<<$'[project]\nname="x"\nversion = "1.2.0+local"'
commit
run scan; eq "T2 local version unsupported" "$rc" 3
repo py3
w pyproject.toml <<<$'[project]\nname="x"\nversion = "1.2.0-rc1"'
commit
run scan
eq "T2 non-normalized exit" "$rc" 3
has "T2 normalized hint" "$out" "1.2.0rc1"
repo py4
w pyproject.toml <<<$'[build-system]\nrequires=["setuptools"]'
w setup.cfg <<<$'[metadata]\nname = x\nversion = 2.0.0'
commit
run scan; has "T2 setup.cfg precedence" "$out" "Current version: 2.0.0"
repo py5
w pyproject.toml <<<$'[project]\nname="x"\ndynamic = ["version"]'
commit
run scan
eq "T2 dynamic version stops" "$rc" 3
has "T2 dynamic msg" "$out" "dynamic"

# --------------------------------------------------------------- T3 Go ----
repo go
w go.mod <<<"module example.com/m"
w main.go <<<'import "example.com/m/sub"'
w sub/sub.go <<<'package sub'
commit; git tag v1.4.2
run scan
has "T3 scheme" "$out" "Scheme: gomod"
has "T3 patch" "$out" "patch -> v1.4.3"
has "T3 major" "$out" "major -> v2.0.0"
run apply v1.4.2 v1.4.3
eq "T3 patch exit" "$rc" 0
clean && ok || bad "T3 patch must not change files"
run apply v1.4.2 v2.0.0 --dry-run
has "T3 dry-run shows rewrite" "$out" "would rewrite: go.mod module path"
clean && ok || bad "T3 dry-run wrote"
run apply v1.4.2 v2.0.0;  eq "T3 major exit" "$rc" 0
has "T3 module path" "$(cat go.mod)" "module example.com/m/v2"
has "T3 imports" "$(cat main.go)" '"example.com/m/v2/sub"'
eq "T3 no tag created" "$(git tag | tr '\n' ' ')" "v1.4.2 "
repo go0; w go.mod <<<"module example.com/z"; commit; git tag v0.9.0
run apply v0.9.0 v1.0.0
eq "T3 v0->v1 exit" "$rc" 0
clean && ok || bad "T3 v0->v1 adds no suffix"
repo goi
w go.mod <<<"module example.com/i"
commit
git tag 'v2.0.0+incompatible'
run scan; eq "T3 +incompatible unsupported" "$rc" 3
repo gom; w go.mod <<<"module example.com/m/v2"; commit; git tag v1.0.0
run scan
eq "T3 path/major mismatch" "$rc" 2
has "T3 mismatch msg" "$out" "module path"

# ----------------------------------------------------------- T4 Node ----
repo node
w package.json <<'EOF'
{
  "name": "x",
  "version": "1.2.0",
  "dependencies": {
    "foo": "1.2.0"
  }
}
EOF
w package-lock.json <<'EOF'
{
  "name": "x",
  "version": "1.1.9",
  "lockfileVersion": 3
}
EOF
w packages/a/package-lock.json <<<'{ "version": "1.2.0" }'
w docs/CHANGELOG.md <<<"## 1.2.0"
commit
run scan; eq "T4 scan exit" "$rc" 2; has "T4 mismatch" "$out" "MISMATCH"
run apply 1.2.0 1.3.0
eq "T4 apply refused" "$rc" 2
clean && ok || bad "T4 refused apply changed files"
run apply 1.2.0 1.3.0 --force; eq "T4 --force exit" "$rc" 0
has "T4 version" "$(cat package.json)" '"version": "1.3.0"'
has "T4 dep untouched" "$(cat package.json)" '"foo": "1.2.0"'
has "T4 nested lock untouched" "$(cat packages/a/package-lock.json)" "1.2.0"
has "T4 nested changelog untouched" "$(cat docs/CHANGELOG.md)" "1.2.0"
has "T4 lock note" "$out" "lockfiles"
repo node2
w package.json <<<$'{\n  "name": "x",\n  "version": "1.0.0"\n}'
w package-lock.json <<<'{ }'
commit
run apply 1.0.0 1.0.1
eq "T4 unparseable secondary refused" "$rc" 2
has "T4 unparseable" "$out" "UNPARSEABLE"
repo node3; w package.json <<<$'{\n  "version": "1.0.0-rc.1"\n}'; commit
run scan
has "T4 prerelease bump" "$out" "prerelease -> 1.0.0-rc.2"
has "T4 release" "$out" "release -> 1.0.0"
repo node4; w package.json <<<$'{\n  "version": "1.0.0+build.5"\n}'; commit
run scan; eq "T4 build metadata unsupported" "$rc" 3

# ---------------------------------------------------------- T5 Rust ----
repo rs
w Cargo.toml <<'EOF'
[package]
name = "c"
version = "0.3.1"

[dependencies]
serde = "0.3.1"
EOF
commit
run scan; has "T5 0.x note" "$out" "Cargo, 0.y.z"
run apply 0.3.1 0.4.0; eq "T5 apply exit" "$rc" 0
has "T5 version" "$(cat Cargo.toml)" 'version = "0.4.0"'
has "T5 serde untouched" "$(cat Cargo.toml)" 'serde = "0.3.1"'
repo rs2
w Cargo.toml <<<$'[package]\nname = "c"\nversion.workspace = true'
commit
run scan; eq "T5 workspace-inherited stops" "$rc" 3

# --------------------------------------------------------- T6 Ruby ----
repo rb
w my-gem.gemspec <<<'  spec.version = My::Gem::VERSION'
w lib/my/gem/version.rb <<<'  VERSION = "1.2.3.rc1"'
commit
run scan
has "T6 reads version.rb" "$out" "Current version: 1.2.3.rc1"
has "T6 prerelease" "$out" "prerelease -> 1.2.3.rc2"
run apply 1.2.3.rc1 1.2.3.rc2; eq "T6 apply exit" "$rc" 0
has "T6 version.rb" "$(cat lib/my/gem/version.rb)" '"1.2.3.rc2"'
repo rb2; w a.gemspec <<<'  spec.version = "1.2.3-rc1"'; commit
run scan; eq "T6 hyphen form stops" "$rc" 3; has "T6 .pre. note" "$out" ".pre."

# -------------------------------------------------------- T7 Maven ----
repo mvn
w pom.xml <<'EOF'
<project>
  <parent>
    <artifactId>p</artifactId>
    <version>9.9.9</version>
  </parent>
  <artifactId>a</artifactId>
  <version>1.2.3-SNAPSHOT</version>
  <dependencies>
    <dependency>
      <artifactId>d</artifactId>
      <version>1.2.3-SNAPSHOT</version>
    </dependency>
  </dependencies>
</project>
EOF
commit
run scan
has "T7 current" "$out" "Current version: 1.2.3-SNAPSHOT"
has "T7 release" "$out" "release -> 1.2.3"
run apply 1.2.3-SNAPSHOT 1.2.3; eq "T7 apply exit" "$rc" 0
has "T7 parent untouched" "$(cat pom.xml)" "<version>9.9.9</version>"
has "T7 project changed" "$(cat pom.xml)" "<version>1.2.3</version>
  <dependencies>"
has "T7 dependency untouched" "$(cat pom.xml)" \
  "<version>1.2.3-SNAPSHOT</version>
    </dependency>"
repo mvn2
w pom.xml <<'EOF'
<project>
  <version>1.0.0</version>
  <modules><module>a</module></modules>
</project>
EOF
commit
run scan; eq "T7 multi-module stops" "$rc" 3

# ------------------------------------------------------- T8 Composer ----
repo php
w composer.json <<<$'{\n  "name": "v/p"\n}'
commit; git tag v1.0.0
run scan; has "T8 tag-derived" "$out" "derived from a git tag"
run apply 1.0.0 1.0.1
eq "T8 exit" "$rc" 0
clean && ok || bad "T8 must write nothing"

# ------------------------------------------ T10 symlink / dash names ----
repo sym
w real.json <<<$'{\n  "name": "x",\n  "version": "1.0.0"\n}'
ln -s real.json package.json; commit
run apply 1.0.0 1.0.1; eq "T10 symlinked manifest refused" "$rc" 2
has "T10 symlink msg" "$out" "is a symlink"
has "T10 target untouched" "$(cat real.json)" '"version": "1.0.0"'
repo dash
w pyproject.toml <<<$'[project]\nname = "x"\nversion = "1.2.0"'
w ./-Mstrict__init__.py <<<'__version__ = "1.2.0"'
commit
run scan; hasnt "T10 dash name scan no perl error" "$out" "Unrecognized switch"
run apply 1.2.0 1.2.1; eq "T10 dash-leading target refused" "$rc" 2
has "T10 dash msg" "$out" "starts with '-'"
has "T10 pyproject untouched" "$(cat pyproject.toml)" 'version = "1.2.0"'

# ------------------------------------------------------ T9 cross-cut ----
cd "$ROOT" && mkdir -p nogit && cd nogit
run scan
eq "T9 non-git exit" "$rc" 1
has "T9 non-git msg" "$out" "Not inside a git repository"
repo gen; w VERSION <<<"3.1.4"; commit
run scan; has "T9 generic semver" "$out" "patch -> 3.1.5"
run apply 3.1.4 3.1.5
eq "T9 generic apply" "$rc" 0
eq "T9 VERSION file" "$(cat VERSION)" "3.1.5"
repo cal; w VERSION <<<"2024.10"; commit
run scan; eq "T9 CalVer unsupported" "$rc" 3
run bogus;  eq "T9 usage exit" "$rc" 1
run apply 1.0.0; eq "T9 missing arg" "$rc" 1

# ------------------------------------------ KB <-> script consistency ----
sch_script="$(grep -o '^next_[a-z0-9]*()' "$S" \
  | sed 's/^next_//; s/()$//' | sort | tr '\n' ' ')"
doc_names() { # marker -> sorted entry names listed between its markers
  sed -n "/<!-- $1:start -->/,/<!-- $1:end -->/p" "$CONV" \
    | grep -o '^- `[a-z0-9-]*`' | sed 's/^- `//; s/`$//' | sort \
    | tr '\n' ' '
}
sch_doc="$(doc_names schemes)"
eq "KB scheme names == script next_* functions" "$sch_doc" "$sch_script"
types_doc="$(doc_names types)"
types_script="$(sed -n '/^usage()/,/^}/p' "$S" | grep '^types:' \
  | sed 's/^types: //' | tr ' ' '\n' | sort | tr '\n' ' ')"
eq "KB project types == script --type list" "$types_doc" "$types_script"

echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
