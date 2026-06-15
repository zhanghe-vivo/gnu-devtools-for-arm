#!/usr/bin/env bash

set -u
set -o errexit
set -o pipefail

PS4='+$(date +%Y-%m-%d:%H:%M:%S) (${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

## Find our executable location
execdir=`dirname $0`
execdir=`cd $execdir; pwd`
default_target=aarch64-none-elf
all_args="$*"
this_script="build-baremetal-toolchain.sh"
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
if [ ! -f "$script_dir/utilities.sh" ]; then
  echo "error:Could not find helper script at $script_dir/utilities.sh"
  exit 1
else
  source $script_dir/utilities.sh
fi
tmpdir=$(mktemp -d)
trap cleanup 0

if [ "$(uname -s)" == "Darwin" ]; then
  set_darwin_envvars
fi

usage ()
{
    cat <<EOF

usage: $this_script [OPTION] [STAGE]

  Build bare metal cross toolchains targetting a specified architecture.

  Interesting stages are:

  clean:
    Wipe the build and head for stage start.

  start
    The default stage.

  check
    A pseudo stage that invokes all available check stages.

  Options are:

  --bugurl=TEXT
    Define the --with-bugurl=FOO configuration option text for relevant
    packages.

  --builddir=DIR
    Define the build directory to be used.  Defaults to the current working
    directory.

  --[no-]check-gdb
    Enable check-gdb as a target for check. Default off. Using this will run
    gdb testing by default.

  --config-flags-binutils=FLAGS
    Specify additional configuration flags for binutils.

  --config-flags-gcc=FLAGS
    Specify additional configuration flags for gcc.

  --config-flags-host-tools=FLAGS
    Specify additional configuration flags for host-tools.

  --config-flags-qemu=FLAGS
    Specify additional configuration flags for qemu.

  --debug
    Options for debugging the toolchain. Builds the host components of
    the toolchain with extra debugging information. Disabled by default.

  --debug-target
    Enable debugging options when building target code (e.g. target
    libraries such as libgcc and libstdc++). Disabled by default.

  --dejagnu-site=Alternative site.exp file to be used.
    Specify name of an alternative site.exp to be used along with --dejagnu-src
    if on a different path. Else this will look for the named site.exp in
    the default location. Default is to use site-exhaustive-fastmodels.exp.

  --dejagnu-src=PATH.
    Define the PATH to a dejagnu install.  Default is to use the relative
    path from gnu-devtools-for-arm/dejagnu in the source area.

  --enable-gdb
  --disable-gdb
    Disable building and testing GDB.  Default enabled.

  --enable-gcc
  --disable-gcc
    Disable building and testing GCC.  Default enabled.

  --enable-newlib
  --disable-newlib
    Disable building and testing Newlib at all.  Default enabled.

  --enable-binutils
  --disable-binutils
    Disable building and testing Binutils.  Default enabled.

  --enable-gdb-with-python=PATH
    Enable building GDB with Python support. PATH determines configuration
    file behavior. 'yes' enables Python support. PATH can be also a path to
    special python-config.sh script which helps to determine local Python
    environment settings.  Default disabled.

  --enable-maintainer-mode
  --disable-maintainer-mode
    Disable or enable maintainer mode.  Default disabled.

  --enable-newlib-nano
  --disable-newlib-nano
    Disable or enable building newlib nano. Default disabled.

  --enable-qemu
  --disable-qemu
    Disable building QEMU.  Default enabled.

  --morello
    Build Morello toolchain.

  -h, --help
    Print brief usage information and exit.

  --host
    The host triple to use. Defaults to that of the build machine
    (i.e. the machine this script is run on).

  --host-toolchain-path=DIR)
    Path to the host toolchain. Default is to use a toolchain
    on the standard PATH.

  -j N
    Use a maximum of N threads of parallel tasks.

  -l N
    Do not spawn additional threads whilst the system load is N (a
    floating-point number) or more

  --ldflags-for-target=FLAGS
    Override the default LD flags used for target library builds.

  --ldflags-for-nano-target=FLAGS
    Override the default LD flags used for target library nano builds.

  --[no-]package
    Package the toolchain.

  --qemu-test-path=PATH
    Define a PATH to be add to environment PATH in order to find
    an appropriate pre-built qemu for testing.

  --[no-]release
    Enable a release build.  Default off.  Turns down self consistency
    checking, turns up optimization and disables debug support.

  --resultdir=PATH
    PATH to a directory to copy all test results into.

  --srcdir=PATH
    PATH to a directory containing all the source modules required
    for the build.  Default <builddir>/src

  --tag=FOO
    Define the build tag / version identifier to be hardwired into
    the built components that support such a concept.  Default 'unknown'.

  --tardir=PATH
    PATH to a directory where the built binary tar balls should be placed.
    Default <builddir>

  --target=GNU-TRIPLE
    The GNU-TRIPLE that the built toolchain should target.  Default
    $default_target.

  --target-board=BOARD
    Specify a dejagnu target board.  Defaults to site.exp selection.

  --timestamp=TIMESTAMP

  --with-language=LANGUAGE
    Add the specified language to the gcc configure line.

  -x
    Enable shell debugging of this script.


EOF
}

## The stack of stages is abstracted out to these functions primarily to
## isolate the pain of bash arrays in conjunction with set -u.  We want
## set -u behaviour on in order to improve script robustness.  However
## bash arrays do not play nicely in this context.  Notably taking
## the ${# size of an empty array will throw an exception.

declare -a stages
stages=()

cwd=`pwd`

set_gdb_config()
{
    # GDB now requires mpfr [1] and prefix is required when using --with-gmp and --with-mpfr options.
    # We still want to keep the previous config flags --with-libgmp-prefix, --with-libgmp-type, --with-libmpfr-type, and --with-libmpfr-prefix
    # so that previous versions of GDB can still build.
    # [1] See commit 991180627851801f1999d1ebbc0e569a17e47c74 from  binutils-gdb--gdb: Use toplevel configure for GMP and MPFR for gdb.
    # https://sourceware.org/git/?p=binutils-gdb.git;a=commit;h=991180627851801f1999d1ebbc0e569a17e47c74

    gdb_config="${binutils_config_flags:-} \
                   --disable-binutils \
                   --disable-sim \
                   --disable-as \
                   --disable-ld \
                   --enable-plugins \
                   --target=$target \
                   --prefix=$prefix \
                   ${bugurl:+--with-bugurl="\"$bugurl\""} \
                   ${hostmpfr:+--with-libmpfr-prefix=$hostmpfr} \
                   ${hostmpfr:+--with-libmpfr-type=static} \
                   ${hostmpfr:+--with-mpfr=$hostmpfr} \
                   ${hostgmp:+--with-libgmp-prefix=$hostgmp} \
                   ${hostgmp:+--with-libgmp-type=static} \
                   ${hostgmp:+--with-gmp=$hostgmp} \
                   ${extra_config_flags_binutils:-} \
                   ${extra_config_flags_host_tools:-} \
                   ${extra_config_flags_gdb:-} "
}

## The layout version for the binary tar ball we create.  This should be stepped
## each time we change the structure of the delivered tar ball.
layout_version="2"

# Reload configuration options
if [ -r build.status ]; then
 . build.status
fi

## Enabled by default, but note may be overridden by host or target options
package_flag=0
release_flag=0
gdb_only_flag=0
extra_languages=""
flag_check_gdb=0
flag_debug_options_flag=0
flag_debug_target_flag=0
flag_enable_gdb=1
flag_enable_gcc=1
flag_enable_binutils=1
flag_enable_newlib=1
flag_enable_newlib_nano=0
flag_enable_newlib_nano_check=0
flag_enable_qemu=1
flag_enable_mingw=0
flag_morello=0

# All the check targets supported by this script.
check_targets="check-binutils check-ld check-gas check-gcc check-g++ check-target-libatomic check-target-libstdc++-v3 check-gdb"
check_nano_targets="check-gcc-nano check-g++-nano check-target-libstdc++-v3-nano"
# Parse command-line options
args=$(getopt -ohj:l:x -l bugurl:,builddir:,config-flags-binutils:,config-flags-gcc:,config-flags-host-tools:,config-flags-qemu:,debug,debug-target,dejagnu-site:,dejagnu-src:,enable-gdb,enable-gdb-with-python:,disable-gdb,enable-gcc,disable-gcc,enable-binutils,disable-binutils,enable-newlib,disable-newlib,enable-maintainer-mode,disable-maintainer-mode,enable-newlib-nano,disable-newlib-nano,enable-newlib-nano-check,disable-newlib-nano-check,enable-qemu,disable-qemu,gdb-only,help,host-toolchain-path:,ldflags-for-target:,ldflags-for-nano-target:,newlib-installdir:,package,no-package,qemu-test-path:,release,no-release,resultdir:,srcdir:,tag:,tardir:,target:,target-board:,timestamp:,with-language:,check-gdb,no-check-gdb,morello,host: -n $(basename "$0") -- "$@")
eval set -- "$args"
while [ $# -gt 0 ]; do
  if [ -n "${opt_prev:-}" ]; then
    eval "$opt_prev=\$1"
    opt_prev=
    shift 1
    continue
  elif [ -n "${opt_append:-}" ]; then
    eval "$opt_append=\"\${$opt_append:-} \$1\""
    opt_append=
    shift 1
    continue
  fi
  case $1 in
  --bugurl)
    opt_prev=bugurl
    ;;
  --builddir)
    opt_prev=builddir
    ;;
  --check-gdb)
    flag_check_gdb=1
    ;;
  --no-check-gdb)
    flag_check_gdb=0
    ;;
  --config-flags-binutils)
    opt_append=extra_config_flags_binutils
    ;;
  --config-flags-gcc)
    opt_append=extra_config_flags_gcc
    ;;
  --config-flags-host-tools)
    opt_append=extra_config_flags_host_tools
    ;;
  --config-flags-qemu)
    opt_append=extra_config_flags_qemu
    ;;
  --debug)
    flag_debug_options_flag=1
    ;;
  --debug-target)
    flag_debug_target_flag=1
    ;;
  --dejagnu-site)
    opt_prev=dejagnu_site
    ;;
  --dejagnu-src)
    opt_prev=dejagnu_src
    ;;
  --enable-gdb)
    flag_enable_gdb=1
    ;;
  --disable-gdb)
    flag_enable_gdb=0
    ;;
  --enable-gcc)
    flag_enable_gcc=1
    ;;
  --disable-gcc)
    flag_enable_gcc=0
    ;;
  --enable-binutils)
    flag_enable_binutils=1
    ;;
  --disable-binutils)
    flag_enable_binutils=0
    ;;
  --enable-maintainer-mode)
    flag_maintainer_mode=1
    ;;
  --disable-maintainer-mode)
    flag_maintainer_mode=0
    ;;
  --morello)
    flag_morello=1
    ;;
  --enable-gdb-with-python)
    opt_prev=gdb_with_python
    ;;
  --enable-newlib)
    flag_enable_newlib=1
    ;;
  --disable-newlib)
    flag_enable_newlib=0
    ;;
  --enable-newlib-nano)
    flag_enable_newlib_nano=1
    ;;
  --disable-newlib-nano)
    flag_enable_newlib_nano=0
    ;;
  --enable-newlib-nano-check)
    flag_enable_newlib_nano_check=1
    ;;
  --disable-newlib-nano-check)
    flag_enable_newlib_nano_check=0
    ;;
  --ldflags-for-target)
    opt_prev=ldflags_for_target
    ;;
  --ldflags-for-nano-target)
    opt_prev=ldflags_for_nano_target
    ;;
  --newlib-installdir)
    opt_prev=newlib_installdir
    ;;
  --enable-qemu)
    flag_enable_qemu=1
    ;;
  --disable-qemu)
    flag_enable_qemu=0
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --host)
    opt_prev=host
    ;;
  --host-toolchain-path)
    opt_prev=host_toolchain_path
    ;;
  -j)
    opt_prev=flag_parallel
    ;;
  -l)
    opt_prev=flag_load
    ;;
  --package)
    package_flag=1
    ;;
  --gdb-only)
    gdb_only_flag=1
    ;;
  --no-package)
    package_flag=0
    ;;
  --qemu-test-path)
    opt_prev=bld_qemu_test_path
    ;;
  --release)
    package_flag=1
    release_flag=1
    ;;
  --no-release)
    release_flag=0
    ;;
  --resultdir)
    opt_prev=resultdir
    ;;
  --srcdir)
    opt_prev=srcdir
    ;;
  --tag)
    opt_prev=tag
    ;;
  --tardir)
    opt_prev=tardir
    ;;
  --target)
    opt_prev=target
    ;;
  --target-board)
    opt_prev=target_board
    ;;
  --timestamp)
    opt_prev=timestamp
    ;;
  --with-language)
    opt_append=extra_languages
    ;;
  -x)
    set -x
    ;;
  --)
    shift
    break 2
    ;;
  esac
  shift 1
done

build=`find_build_triple`
if [[ "$build" == *"darwin"* ]]; then
  TAR_CMD=gtar
  host_is_darwin=1
else
  TAR_CMD=tar
  host_is_darwin=0
fi

if [ -n "${flag_parallel:-}" ]; then
  parallel="-j$flag_parallel"
else
  parallel="-j`number_of_cores`"
fi

if [ -n "${flag_load:-}" ]; then
  parallel="${parallel:-} -l$flag_load"
fi

# If the host triple hasn't been given on the command-line, default to
# the triple of the machine we're building on.
if [ -z "${host:-}" ]; then
  host="$build"
fi

if [ $# -gt 0 ]; then
  stages=("$@")
fi

languages_gcc1=c
languages=c,c++,lto
for language in $extra_languages
do
  languages="$languages,$language"
done

enable_fortran=0
case ",$languages," in
  *,fortran,*)
    enable_fortran=1
    ;;
esac

# Set a default build tag if we didn't get one on the command line.
tag="${tag:-unknown}"

# target
target=${target:-$default_target}

timestamp=${timestamp:-`date +"%Y%m%d-%H%M%S"`}

# builddir: where to build the programs
builddir=${builddir:-$cwd}

# Set a default value for tardir.
tardir="${tardir:-$builddir/bin-tar}"

# Install prefix.
prefix="${prefix:-/}"

# Install tree staging directory.
installdir="${installdir:-$builddir/install}"

# Newlib custom Install tree directory.
newlib_installdir="${newlib_installdir:-$installdir}"

# Install prefix for newlib-nano.
nano_prefix="${nano_prefix:-/}"

# Install tree staging directory for newlib-nano build.
nano_installdir="${nano_installdir:-$builddir/nano_install}"

# Install prefix for qemu.
qemu_prefix="${qemu_prefix:-/}"

# Install tree staging area for qemu build.
qemu_installdir="${qemu_installdir:-$builddir/install-qemu}"

# Install tree staging area for gdb only.
gdb_only_installdir="${gdb_only_installdir:-$builddir/install-gdb}"

srcdir="${srcdir:-$builddir/src}"
objdir="${objdir:-$builddir/obj}"
resultdir="${resultdir:-$builddir/results}"
build_flags_path="$installdir$prefix/.build_flags"

# Install dir for host tools.
host_tools_install=$builddir/host-tools

# dejagnu site.exp
dejagnu_site="${dejagnu_site:-site-exhaustive-fastmodels.exp}"

if [ -z "${dejagnu_src:-}" ]; then
  # The dejagnu directory should be available in gnu-devtools-for-arm
  find_component_or_error "$srcdir/gnu-devtools-for-arm" dejagnu
fi
#Set the DEJAGNU environment variable for check targets
set_env_var DEJAGNU "$dejagnu_src/$dejagnu_site"
check_if_readable $DEJAGNU

#libstdcxx_flags=--disable-wchar_t
libstdcxx_flags=

cflags_for_target_common="-ffunction-sections -fdata-sections"
if [ $flag_debug_target_flag -eq 0 ]; then
  cflags_for_target="$cflags_for_target_common -O2 -g"
  cflags_for_nano_target="$cflags_for_target_common -Os -g"
else
  cflags_for_target="$cflags_for_target_common -O0 -g3"
  cflags_for_nano_target="$cflags_for_target"
fi
cxxflags_for_target="$cflags_for_target"
cxxflags_for_nano_target="$cflags_for_nano_target -fno-exceptions"

if [ $release_flag -eq 0 ]; then
  if [ $flag_debug_options_flag -eq 0 ]; then
    cflags="-O1 -g"
  else
    cflags="-O0 -g3"
  fi
  flag_check_final=yes
else
  cflags="-O2"
  flag_check_final=release
fi

newlib_config_flags_common=""
# Disable syscalls implemented in newlib, use libgloss implementations instead.
newlib_config_flags_common="$newlib_config_flags_common --disable-newlib-supplied-syscalls"
# Allow locking routines to be retargeted at link time
newlib_config_flags_common="$newlib_config_flags_common --enable-newlib-retargetable-locking"
# A security issue "Multiple NULL pointer dereference vulnerabilities in
# newlib" has been found in newlib < 3.3.0
newlib_config_flags_common="$newlib_config_flags_common --enable-newlib-reent-check-verify"

newlib_config_flags="$newlib_config_flags_common"
# Support for the 'long long' type in IO formatting.
newlib_config_flags="$newlib_config_flags --enable-newlib-io-long-long"
# Support for C99 format specifiers in printf/scanf.
newlib_config_flags="$newlib_config_flags --enable-newlib-io-c99-formats"
# Enable finalization function registration using atexit
newlib_config_flags="$newlib_config_flags --enable-newlib-register-fini"
# Multibyte support for JIS, SJIS, and EUC-JP implemented.
newlib_config_flags="$newlib_config_flags --enable-newlib-mb"

newlib_nano_config_flags="$newlib_config_flags_common"
# Nano build uses the dedicated, small footprint malloc implementation.
newlib_nano_config_flags="$newlib_nano_config_flags --enable-newlib-nano-malloc"
# NEWLIB does optimization when `fprintf to write only unbuffered unix
# file'.  It creates a temorary buffer to do the optimization that
# increases stack consumption by about `BUFSIZ' bytes.  This option
# disables the optimization and saves size of text and stack.
newlib_nano_config_flags="$newlib_nano_config_flags --disable-newlib-unbuf-stream-opt"
# There are two versions of reentrancy support, normal, and small,
# select the small version
newlib_nano_config_flags="$newlib_nano_config_flags --enable-newlib-reent-small"
# Disable fseek optimization.  It can decrease code size of application
# calling `fseek`.
newlib_nano_config_flags="$newlib_nano_config_flags --disable-newlib-fseek-optimization"
# Nano build disables IO formatting support for floats etc.
newlib_nano_config_flags="$newlib_nano_config_flags --enable-newlib-nano-formatted-io"
# NEWLIB implements the vector buffer mechanism to support stream IO
# buffering required by C standard.  This feature is possibly
# unnecessary for embedded systems which won't change file buffering
# with functions like `setbuf' or `setvbuf'.  Disabled for nano build.
newlib_nano_config_flags="$newlib_nano_config_flags --disable-newlib-fvwrite-in-streamio"
# C99 states that each stream has an orientation, wide or byte.  This
# feature is possibly unnecessary for embedded systems which only do
# byte input/output operations on stream.  It can decrease code size
# by disable the feature.
newlib_nano_config_flags="$newlib_nano_config_flags --disable-newlib-wide-orient"
# Enable lite exit, a size-reduced implementation of exit that doesn't
# invoke clean-up functions such as _fini or global destructors.
newlib_nano_config_flags="$newlib_nano_config_flags --enable-lite-exit"
# Enable atexit data structure as global variable.  By doing so it is
# moves the atexit variables from struct _reent in newlib/libc/stdlib/reent.h
# to static global vars in __atexit.c. It can be garbage collected if atexit
# is not referenced.  Note that making atexit static global will make newlib-nano
# thread-unsafe.
newlib_nano_config_flags="$newlib_nano_config_flags --enable-newlib-global-atexit"

# Target library config scripts need this to link a test program
binutils_config_flags="--enable-initfini-array --disable-nls --without-x --disable-gdbtk --without-tcl --without-tk"
case $target in
aarch64*-*-elf | aarch64*-elf)
  ldflags_for_target="${ldflags_for_target:- -specs rdimon.specs}"
  binutils_config_flags="--enable-64-bit-bfd --enable-targets=arm-none-eabi,aarch64-none-linux-gnu,aarch64-none-elf ${binutils_config_flags:-}"
  if [ $flag_enable_newlib_nano -eq 1 ]; then
    printf "error: --enable-newlib-nano incompatible with $target\n" >&2
    exit 2
  fi
  ;;
arm*-*-eabi | arm*-eabi)
  ldflags_for_target="${ldflags_for_target:- -specs aprofile-validation.specs}"
  # When we enable --enable-newlib-nano-formatted-io, floating-point
  # support is split out of the formatted I/O code into weak functions
  # which are not linked by default.  Programs that need floating-point
  # I/O support must explicitly request linking of one or both of the
  # floating-point functions: _printf_float or _scanf_float.
  # This can be done at link time using the -u option which can be passed
  # to either gcc or ld.  The -u option forces the link to resolve those
  # function references.
  if [ $flag_enable_newlib_nano -eq 1 ]; then
    ldflags_for_nano_target="${ldflags_for_nano_target:- -specs aprofile-validation.specs -Wl,-u,_printf_float,-u,_scanf_float}"
  fi
  ;;
*)
  ;;
esac

# Possibly maintainer mode for binutils tree
if [ ${flag_maintainer_mode:-0} -eq 1 ]; then
    binutils_config_flags="${binutils_config_flags:-} --enable-maintainer-mode"
fi

bld_qemu_test_path=${bld_qemu_test_path:-$qemu_installdir$qemu_prefix/bin}

# Install dir needs to be in path to find sub-tools
PATH="$installdir$prefix/bin:$bld_qemu_test_path:$execdir:$PATH"

if [ -n "${host_toolchain_path:-}" ]; then
  PATH="$host_toolchain_path:$PATH"
fi

if [ "$builddir" != "$cwd" ]; then
  [ -d $builddir ] || mkdir -p $builddir
  cd $builddir
fi

if empty_stages_p; then
  if [ -r ,stage ]; then
    # Continue from last failing stage
    stages=(`cat ,stage`)
  else
    # Build from the start
    stages=(start)
  fi
fi

for component in gcc linux gmp mpfr mpc binutils newlib isl
do
  find_component_or_error "$srcdir" $component
done

for component in cloog libiconv qemu
do
  find_component "$srcdir" "$component" || true
done

if [ -d "$srcdir/binutils-gdb" ]; then
  binutils_src="$srcdir/binutils-gdb"
fi

gdb_src="$binutils_src"
if [ -d "$srcdir/binutils-gdb--gdb" ]; then
  gdb_src="$srcdir/binutils-gdb--gdb"
fi

hostgmp="$host_tools_install"
hosticonv="$host_tools_install"
hostmpfr="$host_tools_install"
hostmpc="$host_tools_install"
hostexpat="$host_tools_install"

# We are (currently) tolerant to absence ISL and CLOOG hence we only setup
# the relevant --with- flags if the source is present.  These are set here
# rather than in the corresponding build or install stages because it is a
# valid use case to repeatedly restart a build at an arbitrary stage.
if [ -d "$srcdir/isl" ];
then
  hostisl="$host_tools_install"

  # CLOOG requires ISL hence only enable if ISL is also enabled.
  if [ -d "$srcdir/cloog" ];
  then
    hostcloog="$host_tools_install"
  fi
fi

case "${extra_config_flags_host_tools:-}" in
*--host=*mingw*)
  # MinGW builds are special case and are only used for toolchain official
  # releases. We do not redistribute QEMU. Newlib and Newlib-nano are off
  # as we build Newlib* libraries (if needed) in separate build passes.
  flag_enable_mingw=1
  flag_enable_qemu=0
  flag_enable_newlib=0
  flag_enable_newlib_nano=0
  languages_gcc1=c,c++
  # Explicitly use -static-libstdc++ and -static-libgcc
  # Default linking behavior of GDB changed. It was static linking by
  # default. Now it has to be explicitly enabled with
  # --with-static-standard-libraries flag
  extra_config_flags_gdb="--disable-source-highlight --with-static-standard-libraries"
  ;;
esac

if [ $flag_enable_mingw -eq 0 ]; then
  # For MinGW, --host is passed via $extra_config_flags_host_tools.
  # FIXME: MinGW builds should really use this new --host option instead.
  # Then we can remove this logic.
  host_config_flag="--host=$host"
fi

RUNTESTFLAGS="${target_board:+--target_board=$target_board} ${RUNTESTFLAGS:-}"

# 8GB limit on ulimit -v
# Note that 32 bit qemu guest on 64 bit host will request 4GB reserved
# virtual address space.
memlimit=8000000

if [ $flag_morello -eq 1 ]; then
  extra_config_flags_gcc="${extra_config_flags_gcc:-} --disable-libsanitizer --disable-libatomic"
fi

while true; do
  if empty_stages_p; then
    push_stages stop
  fi

  # Record the current build stage and shift
  echo "${stages[*]}" >,stage

  pop_stages
  stage="$item"
  echo "($stage)"

  case "$stage" in
  clean)
    rm -rf "$installdir"
    rm -rf "$nano_installdir"
    rm -rf "$qemu_installdir"
    rm -rf "$gdb_only_installdir"
    rm -rf "$objdir"
    push_stages "start"
    ;;

  start-bootstrap-newlib)
    mk_bin_dirs $prefix
    push_stages gmp mpfr mpc isl cloog iconv binutils gdb gcc1 newlib newlib-nano gcc2 gcc2-nano copy_newlib_build_flags
    ;;

  start)
    mk_bin_dirs $prefix
    write_build_status > build.status
    push_stages gmp mpfr mpc isl cloog qemu iconv binutils gdb gcc1 newlib newlib-nano gcc2 gcc2-nano perms
    ;;

  gmp)
    gmp_srcdir=$gmp_src
    gmp_objdir=$objdir/gmp
    gmp_config="--disable-maintainer-mode --disable-shared --prefix=${host_tools_install} ${extra_config_flags_host_tools:-} ${host_config_flag:-}"
    do_config_build_install gmp
    ;;

  mpfr)
    mpfr_srcdir=$mpfr_src
    mpfr_objdir=$objdir/mpfr
    mpfr_config="--disable-maintainer-mode --disable-shared --prefix=${host_tools_install} ${hostgmp:+--with-gmp=$hostgmp} ${extra_config_flags_host_tools:-}"
    do_config_build_install mpfr
    ;;

  mpc)
    mpc_srcdir=$mpc_src
    mpc_objdir=$objdir/mpc
    mpc_config="--disable-maintainer-mode --disable-shared --prefix=${host_tools_install} ${hostgmp:+--with-gmp=$hostgmp} ${hostmpfr:+--with-mpfr=$hostmpfr} ${extra_config_flags_host_tools:-}"
    do_config_build_install mpc
    ;;

  isl)
    if [ -n "${hostisl:-}" ]; then
      isl_srcdir=$isl_src
      isl_objdir=$objdir/isl
      isl_config="--disable-maintainer-mode --disable-shared --prefix=${host_tools_install} ${hostgmp:+--with-gmp-prefix=$hostgmp} ${extra_config_flags_host_tools:-}"
      do_config_build_install isl
    fi
    ;;

  cloog)
    if [ -n "${hostcloog:-}" ]; then
      cloog_srcdir=$cloog_src
      cloog_objdir=$objdir/cloog
      cloog_config="--disable-maintainer-mode --disable-shared --prefix=${host_tools_install} ${hostgmp:+--with-gmp-prefix=$hostgmp} ${hostisl:+--with-isl-prefix=$hostisl} ${extra_config_flags_host_tools:-}"
      do_config_build_install cloog
    fi
    ;;

  qemu)
    if [ $flag_enable_qemu -eq 1 -a -n "${qemu_src:-}" ]; then
      qemu_target="aarch64-linux-user,aarch64_be-linux-user"
      case "$target" in
        arm*)
          qemu_target="arm-linux-user,armeb-linux-user" ;;
      esac
      qemu_parallel=0
      qemu_srcdir="$qemu_src"
      qemu_objdir="$objdir/qemu"
      qemu_config="--target-list=$qemu_target \
                   --prefix=${qemu_installdir}/${prefix} \
                   --disable-strip \
                   --disable-werror \
                   --disable-docs \
                   --disable-kvm \
                   --disable-system \
                   --disable-tools \
                   ${extra_config_flags_qemu:-}"
      qemu_destdir=
      do_config_build_install qemu
    fi
    ;;

  iconv)
    if [ $flag_enable_mingw -eq 1 ]; then
      iconv_srcdir="$libiconv_src"
      iconv_objdir="$objdir/iconv"
      iconv_config="--prefix=$hosticonv \
                    --disable-shared \
                     ${extra_config_flags_host_tools:-}"
      do_config_build_install iconv
    fi
    ;;

  binutils)
    if [ $flag_enable_binutils -eq 1 ]; then
      binutils_srcdir=$binutils_src
      binutils_objdir=$objdir/binutils
      extra_config_flags_binutils="${extra_config_flags_binutils:-} --without-debuginfod"
      if [ $flag_enable_mingw -eq 1 ]; then
	extra_config_flags_binutils="${extra_config_flags_binutils:-} --disable-werror"
      fi

      if [ ${flag_maintainer_mode:-0} -eq 1 ]; then
	extra_config_flags_binutils="${extra_config_flags_binutils:-} --enable-maintainer-mode"
      fi

      # For AArch64 turn on encoding/decoding debugging if not in release mode.
      if [ $release_flag -eq 0 ]; then
	case $target in
	aarch64*-*-elf | aarch64*-elf)
	  cflags="$cflags -DDEBUG_AARCH64"
	  ;;
	*)
	  ;;
	esac
      fi

      binutils_cflags="$cflags"
      binutils_cxxflags="$cflags"
      binutils_config="${binutils_config_flags:-} \
			  --enable-plugins \
			  --disable-gdb \
			  --without-gdb \
			  --target=$target \
			  --prefix=$prefix \
			  ${bugurl:+--with-bugurl="\"$bugurl\""} \
			  --with-sysroot=$prefix/$target \
			  ${extra_config_flags_host_tools:-} \
			  ${extra_config_flags_binutils:-}"

      binutils_build_targets="all-binutils all-gas all-gprof all-ld"
      binutils_install_targets="install-binutils install-gas install-ld install-gprof"
      binutils_destdir=${installdir}
      do_config_build_install binutils
      # After building: Also install to nano_installdir, if building a nano toolchain
      if [ $flag_enable_mingw -eq 0 ]; then
	if [ $flag_enable_newlib_nano -eq 1 ]; then
	  binutils_destdir=${nano_installdir}
	  binutils_install_targets="install-binutils install-gas install-ld install-gprof"
	  do_install binutils
	fi
      fi
    fi
    ;;

  gdb)
    if [ $flag_enable_gdb -eq 1 ]; then
      extra_config_flags_gdb="${extra_config_flags_gdb:-} --without-debuginfod"
      if [ -d "$srcdir/libexpat" ]; then
          # With libexpat component present add libexpat to GDB configuration
          # Static link libexpat
          extra_config_flags_gdb="${extra_config_flags_gdb:-} --with-expat --with-libexpat-prefix=$hostexpat --with-libexpat-type=static"
          push_stages "libexpat" "main-gdb"
      else
          push_stages "main-gdb"
      fi
    fi
    ;;

  libexpat)
    libexpat_srcdir="$srcdir/libexpat/expat"
    libexpat_objdir="$objdir/libexpat"

    libexpat_config="--prefix="$hostexpat" \
        --without-docbook \
        --without-xmlwf \
        ${extra_config_flags_host_tools:-}"
    libexpat_build_targets="lib"
    libexpat_install_targets="install"
    do_config_build_install libexpat
    # Upgrade Note: Updating libexpat from version 2.2.5 to 2.7.1.
    # Workaround: Delete libexpat.la to prevent incorrect linker flags from being injected
    # when building GDB with a static archive of libexpat. This .la file may cause libtool
    # or the build system to pull in unnecessary dependencies like -lm and the libm.a static
    # archive, which leads to link errors in environments where libm is not available.
    # Removing the .la file ensures a cleaner and more predictable link process.
    rm -f $hostexpat/lib/libexpat.la
    ;;

  main-gdb)
    gdb_srcdir="$gdb_src"
    gdb_objdir="$objdir/gdb"
    gdb_cflags="$cflags"
    gdb_cxxflags="$cflags"
    gdb_build_targets="all-gdb html-gdb"
    gdb_install_targets="install-gdb install-html-gdb"
    gdb_destdir="${installdir}"

    set_gdb_config
    gdb_config="${gdb_config:-} --with-python=no"

    do_config_build_install gdb
    if [ $flag_enable_newlib_nano -eq 1 ]; then
      gdb_destdir=${nano_installdir}
      do_install gdb
    fi

    if [ "$gdb_only_flag" -eq 1 ]; then
      gdb_destdir="${gdb_only_installdir}"
      do_install gdb
    fi

    if [ ${gdb_with_python:-no} != "no" ]; then
        push_stages "gdb-python"
    fi
    ;;

  gdb-python)
    gdb_python_srcdir="$gdb_src"
    gdb_python_objdir="$objdir/gdb_python"
    gdb_python_cflags="$cflags"
    gdb_python_cxxflags="$cflags"

    set_gdb_config
    gdb_python_config="${gdb_config:-} --with-python=$gdb_with_python --program-prefix=$target- --program-suffix=-py"
    gdb_python_build_targets="all-gdb"
    gdb_python_install_targets="install-gdb"
    gdb_python_destdir="${installdir}"
    do_config_build_install gdb_python
    if [ $flag_enable_newlib_nano -eq 1 ]; then
      gdb_destdir=${nano_installdir}
      do_install gdb_python
    fi
    if [ "$gdb_only_flag" -eq 1 ]; then
      gdb_python_destdir="${gdb_only_installdir}"
      do_install gdb_python
    fi
    ;;

  gcc1)
    if [ $flag_enable_gcc -eq 1 ]; then
      if [ $flag_enable_mingw -eq 1 ]; then
        extra_config_flags_gcc="${extra_config_flags_gcc:-} --with-libiconv-prefix=$hosticonv"
        host_config_options=
      else
        host_config_options="\
          ${hostgmp:+--with-gmp=$hostgmp} \
          ${hostmpfr:+--with-mpfr=$hostmpfr} \
          ${hostmpc:+--with-mpc=$hostmpc} \
          ${hostcloog:+--with-cloog=$hostcloog} \
          ${hostisl:+--with-isl=$hostisl}"
      fi
      gcc1_srcdir=$gcc_src
      gcc1_objdir=$objdir/gcc1
      gcc1_build_targets="all-gcc"
      gcc1_cflags="$cflags"
      gcc1_cxxflags="$cflags"
      gcc1_cflags_for_target="${cflags_for_target:-}"
      gcc1_cxxflags_for_target="${cxxflags_for_target:-}"
      gcc1_ldflags_for_target="${ldflags_for_target:-}"
      gcc1_install_targets="install-gcc"
      # Don't use maintainer mode for gcc tree
      # just touch the auto-generated files
      (cd $gcc_src; sh ./contrib/gcc_update --touch)

      # gcc2 has to be configured with the absolute install path in $prefix
      # as it uses $prefix to search for headers etc while configuring
      # libraries (libstdc++ etc). Therefore $prefix becomes $installdir/$prefix.
      # gcc1 can be configured with a relative prefix, but keep it consistent with
      # gcc2 and pass an absolute path in prefix.
      # Because we supply the absolute path for $prefix here, we don't need
      # a DESTDIR to be set for the install stage.
      gcc1_config="$host_config_options \
          --target=$target \
		      --prefix=$installdir \
		      --disable-shared \
		      --disable-nls \
		      --disable-threads \
		      --enable-checking=$flag_check_final \
		      --enable-languages=$languages_gcc1 \
		      --without-cloog \
		      --without-isl \
		      --with-newlib \
		      --without-headers \
                      --with-gnu-as \
                      --with-gnu-ld \
                      ${bugurl:+--with-bugurl="\"$bugurl\""} \
                      --with-sysroot=$installdir/$target \
		      ${extra_config_flags_gcc:-}"
      do_config_build_install gcc1
    fi
    ;;

  newlib)
    if [ $flag_enable_newlib -eq 1 ]; then

      extra_newlib_cflags=""
      if [ $flag_morello -eq 1 ]; then
        extra_newlib_cflags="-DWANT_CHERI_QUALIFIER_MACROS -D__cheri_fromcap="
      fi
      gccbin="$objdir/gcc1/gcc"
      newlib_objdir="$objdir/newlib"
      newlib_srcdir="$newlib_src"
      newlib_destdir=$newlib_installdir
      newlib_config="${newlib_config_flags:-} \
                       --target=$target \
                       --prefix=$prefix \
                       ${bugurl:+--with-bugurl="\"$bugurl\""}"
      newlib_cflags="$cflags"
      newlib_cflags_for_target="${cflags_for_target:-} ${extra_newlib_cflags:-}"
      newlib_cxxflags_for_target="${cxxflags_for_target:-} ${extra_newlib_cflags:-}"
      newlib_ldflags_for_target="${ldflags_for_target:-}"
      newlib_extra_config_envflags="CC_FOR_TARGET=\"$gccbin/xgcc -B$gccbin/\""
      newlib_build_targets="all-target-newlib all-target-libgloss"
      newlib_install_targets="install-target-newlib install-target-libgloss"
      do_config_build_install newlib
    fi
    ;;

  # This is a dummy stage that will only perform an install of an already-built
  # Newlib.  This is needed for the current split-build of the mingw-hosted
  # toolchains only and it is invoked explicitly as a single-stage run of
  # "build-baremetal-toolchain.sh <options> install-newlib".  When we update the higher-level
  # scripts to no longer require this explicit install invocation, this stage
  # can be removed.
  install-newlib)
    if [ $flag_enable_newlib -eq 1 ]; then
      newlib_objdir="$objdir/newlib"
      newlib_destdir=$newlib_installdir
      newlib_install_targets="install-target-newlib install-target-libgloss"
      do_install newlib
    fi
    ;;

  newlib-nano)
    if [ $flag_enable_newlib_nano -eq 1 ]; then

      gccbin="$objdir/gcc1/gcc"
      newlib_nano_objdir="$objdir/newlib-nano"
      newlib_nano_srcdir="$newlib_src"
      newlib_nano_destdir=$nano_installdir
      newlib_nano_config="${newlib_nano_config_flags:-} \
                       --target=$target \
                       --prefix=$nano_prefix \
		        ${bugurl:+--with-bugurl="\"$bugurl\""}"
      newlib_nano_cflags="$cflags"
      newlib_nano_cflags_for_target="${cflags_for_nano_target:-}"
      newlib_nano_cxxflags_for_target="${cxxflags_for_nano_target:-}"
      newlib_nano_ldflags_for_target="${ldflags_for_nano_target:-}"
      newlib_nano_extra_config_envflags="CC_FOR_TARGET=\"$gccbin/xgcc -B$gccbin/\""
      newlib_nano_build_targets="all-target-newlib all-target-libgloss"
      newlib_nano_install_targets="install-target-newlib install-target-libgloss"
      do_config_build_install newlib_nano
      mkdir -p $installdir/$prefix/$target/include/newlib-nano
      cp -f $nano_installdir/$nano_prefix/$target/include/newlib.h $installdir/$prefix/$target/include/newlib-nano
      target_gcc="$gccbin/xgcc -B$gccbin/"
      for multilib in $($target_gcc -print-multi-lib); do
	multi_dir="${multilib%%;*}"
	src_dir="$nano_installdir/$nano_prefix/$target/lib/$multi_dir"
	dst_dir="$installdir/$prefix/$target/lib/$multi_dir"
	cp -f "${src_dir}/libc.a" "${dst_dir}/libc_nano.a"
	cp -f "${src_dir}/libg.a" "${dst_dir}/libg_nano.a"
	cp -f "${src_dir}/librdimon.a" "${dst_dir}/librdimon_nano.a"
	cp -f "${src_dir}/nano.specs" "${dst_dir}/"
	cp -f "${src_dir}/rdimon.specs" "${dst_dir}/"
	cp -f "${src_dir}/nosys.specs" "${dst_dir}/"
	# Here it is safe to replace non-nano *crt0.o with the nano version because
	# the the only difference in startup is that atexit is made a weak reference
	#  in nano. With lite exit libs, a program not explicitly calling atexit or on_exit
	# will escape from the burden of cleaning up code. A program with atexit
	# or on_exit will work consistently to normal libs.
	cp -f "${src_dir}/"*crt0.o "${dst_dir}/"
      done
    fi
    ;;

  gcc2)
    if [ $flag_enable_gcc -eq 1 ]; then
      if [ $flag_enable_mingw -eq 1 ]; then
        extra_config_flags_gcc="${extra_config_flags_gcc:-} --with-libiconv-prefix=$hosticonv --enable-mingw-wildcard"
      fi
      # gcc2 has to be configured with the absolute install path in $prefix
      # as it uses $prefix to search for headers etc while configuring
      # libraries (libstdc++ etc). Therefore $prefix becomes $installdir/$prefix.
      # Because we supply the absolute path for $prefix here, we don't need
      # a DESTDIR to be set for the install stage.
      gcc2_config="--target=$target \
			--prefix=$installdir \
			${hostgmp:+--with-gmp=$hostgmp} \
			${hostmpfr:+--with-mpfr=$hostmpfr} \
			${hostmpc:+--with-mpc=$hostmpc} \
			${hostcloog:+--with-cloog=$hostcloog} \
			${hostisl:+--with-isl=$hostisl} \
			--disable-shared \
			--disable-nls \
			$( [ "$target" = "arm-none-fv-eabi" ] && echo "--enable-threads=posix" || echo "--enable-threads=single" ) \
			--enable-checking=$flag_check_final \
			--enable-languages=$languages \
			--with-newlib \
                        --with-gnu-as \
			--with-headers=yes \
                        --with-gnu-ld \
			--with-native-system-header-dir="/include" \
                        --with-sysroot=$installdir/$target \
			${bugurl:+--with-bugurl="\"$bugurl\""} \
			$libstdcxx_flags \
			${extra_config_flags_gcc:-} \
			${extra_config_flags_host_tools:-}"

      gcc2_srcdir="$gcc_src"
      gcc2_objdir="$objdir/gcc2"
      gcc2_cxxflags="$cflags"
      gcc2_cflags_for_target="${cflags_for_target:-}"
      gcc2_cxxflags_for_target="${cxxflags_for_target:-}"
      gcc2_ldflags_for_target="${ldflags_for_target:-}"
      do_config gcc2
      if [ $flag_enable_mingw -eq 1 ]; then
	gcc2_build_targets="all-gcc html-gcc"
	gcc2_cflags="$cflags -static-libgcc -static-libstdc++ -Wl,-Bstatic,-lpthread,-Bdynamic"
	gcc2_install_targets="install-gcc install-html-gcc"
	do_make gcc2
      else
	gcc2_build_targets="all-gcc all-target-libgcc"
	gcc2_extra_make_envflags="LDFLAGS_FOR_TARGET=${ldflags_for_target:-}"
	gcc2_cflags="$cflags"
  gcc2_install_targets="install-gcc install-target-libgcc install-html-gcc install-target-libstdc++-v3 install-html-target-libstdc++-v3"
  if [ $enable_fortran -eq 1 ]; then
    gcc2_install_targets="$gcc2_install_targets install-target-libgfortran"
  fi
	do_make gcc2
  gcc2_build_targets="all-target-libstdc++-v3 html-gcc html-target-libstdc++-v3"
  if [ $enable_fortran -eq 1 ]; then
    gcc2_build_targets="$gcc2_build_targets all-target-libquadmath all-target-libgfortran"
  fi
	do_make gcc2
      fi
      do_install gcc2
    fi
    ;;

  gcc2-nano)
    if [ $flag_enable_mingw -eq 0 ]; then
      if [ $flag_enable_newlib_nano -eq 1 ]; then
	# See comments above in gcc2 as to why we give absolute path to $prefix.
	gcc2_nano_config="--target=$target \
                               --prefix=$nano_installdir/$nano_prefix \
                               ${hostgmp:+--with-gmp=$hostgmp} \
                               ${hostmpfr:+--with-mpfr=$hostmpfr} \
                               ${hostmpc:+--with-mpc=$hostmpc} \
                               ${hostcloog:+--with-cloog=$hostcloog} \
                               ${hostisl:+--with-isl=$hostisl}\
                               --disable-shared \
                               --disable-nls \
                               $( [ "$target" = "arm-none-fv-eabi" ] && echo "--enable-threads=posix" || echo "--enable-threads=single" ) \
                               --enable-checking=$flag_check_final \
                               --enable-languages=$languages \
                               --with-newlib \
                               --with-gnu-as \
                               --with-gnu-ld \
                               --with-sysroot=$nano_installdir/$nano_prefix/$target \
                               ${bugurl:+--with-bugurl="\"$bugurl\""} \
                               $libstdcxx_flags \
                               ${extra_config_flags_gcc:-}"
	gcc2_nano_srcdir="$gcc_src"
	gcc2_nano_objdir="$objdir/gcc2-nano"
	gcc2_nano_cxxflags="$cflags"
	gcc2_nano_cflags="$cflags"
	gcc2_nano_cflags_for_target="${cflags_for_nano_target:-}"
	gcc2_nano_cxxflags_for_target="${cxxflags_for_nano_target:-}"
	gcc2_nano_ldflags_for_target="${ldflags_for_nano_target:-}"
	gcc2_nano_extra_make_envflags="LDFLAGS_FOR_TARGET=${ldflags_for_nano_target:-}"
  gcc2_nano_install_targets="install-gcc install-target-libgcc install-html-gcc install-target-libstdc++-v3 install-html-target-libstdc++-v3"
  if [ $enable_fortran -eq 1 ]; then
    gcc2_nano_install_targets="$gcc2_nano_install_targets install-target-libgfortran"
  fi
	do_config gcc2_nano
	gcc2_nano_build_targets="all-gcc all-target-libgcc"
	do_make gcc2_nano
  gcc2_nano_build_targets="all-target-libstdc++-v3 html-gcc html-target-libstdc++-v3"
  if [ $enable_fortran -eq 1 ]; then
    gcc2_nano_build_targets="$gcc2_nano_build_targets all-target-libquadmath all-target-libgfortran"
  fi
	do_make gcc2_nano
	do_install gcc2_nano

	gccbin="$objdir/gcc2-nano/gcc"
	target_gcc="$gccbin/xgcc -B$gccbin/"
	for multilib in $($target_gcc -print-multi-lib); do
	  multi_dir="${multilib%%;*}"
	  src_dir="$nano_installdir/$nano_prefix/$target/lib/$multi_dir"
	  dst_dir="$installdir/$prefix/$target/lib/$multi_dir"
	  cp -f "${src_dir}/libstdc++.a" "${dst_dir}/libstdc++_nano.a"
	  cp -f "${src_dir}/libsupc++.a" "${dst_dir}/libsupc++_nano.a"
	done
      fi
    fi
    ;;

  copy_newlib_build_flags)
    # Mingw release pipeline uses .build_flags file from build-mingw-arm-none-eabi tar file to create the manifest file.
    # To populate the missing gcc2_nano_configure, newlib_nano_configure, newlib_configure build flags in arm-none-eabi-manifest.txt
    # for the windows arm-none-eabi toolchain build, we are extracting and appending build flags from newlib build as a workround
    newlib_build_flags_path="$newlib_installdir$prefix/.build_flags"
    base_installdir=$(dirname $(dirname "$installdir"))
    mingw_dir=$(find "$base_installdir" -type d -name "*-mingw-*" -print -quit)
    if [ -n "$mingw_dir" ]; then
        mingw_build_flags_path="$mingw_dir/install/.build_flags"
        if [ -f "$mingw_build_flags_path" ]; then
            newlib_flags=$(cat $newlib_build_flags_path)
            flags=$(echo "$newlib_flags" | grep -E '^(gcc2_nano_configure=|newlib_nano_configure=|newlib_configure=)')
            echo "$flags" >> "$mingw_build_flags_path"
        else
            echo "Mingw .build_flags file does not exist in $mingw_dir/install"
        fi
    else
        echo "Directory matching '*-mingw-*' not found."
    fi
    ;;

  perms)
    if [ "$package_flag" -eq 1 ]; then
      perms_dir="$installdir$prefix"
      if [ "$newlib_installdir" != "$installdir" ]; then
        perms_dir="$newlib_installdir"
      fi
      strip_lib "$perms_dir"
      # user: read/write; group: read-only; others: read-only
      chmod -R u+rw,go+r,go-w "$perms_dir"
      # propagate user's execute permission to group
      find "$perms_dir" -perm -0100 -print0 | xargs -0 chmod g+x
      push_stages tar
    fi
    ;;

  tar)
    if [ $package_flag -eq 1 ]; then
      tarball="$tardir/$target-tools.tar.xz"
      tar_dir="$installdir$prefix"
      if [ "$newlib_installdir" != "$installdir" ]; then
        tarball="$tardir/newlib.tar.xz"
        tar_dir="$newlib_installdir"
      fi

      echo "$layout_version" > "$tar_dir/.version"
      mkdir -p "$tardir"
      rm -f "$tarball"
      ${TAR_CMD} -c -C "$tar_dir" -J -f "$tarball.t" --owner 0 --group 0 --mode=a+u,og-w --exclude="*gccbug" .
      mv "$tarball.t" "$tarball"
      chmod 444 "$tarball"

      if [ ${flag_enable_qemu} -eq 1 ]; then
        echo "$layout_version" > "$qemu_installdir$qemu_prefix/.version"
        tarball="$tardir/$target-qemu.tar.xz"
        rm -f "$tarball"
        if test "$qemu_installdir$qemu_prefix" != "$installdir$prefix" -a -d "$qemu_installdir$qemu_prefix"
        then
          ${TAR_CMD} -c -C "$qemu_installdir$qemu_prefix" -J -f "$tarball.t" --owner 0 --group 0 --mode=a+u,og-w .
          mv "$tarball.t" "$tarball"
          chmod 440 "$tarball"
        fi
      fi
      if [ $gdb_only_flag -eq 1 ]; then
        echo "$layout_version" > "$gdb_only_installdir/.version"
        tarball="$tardir/$target-gdb.tar.xz"
        rm -f "$tarball"
        if [ -d "$gdb_only_installdir" ]; then
          ${TAR_CMD} -c -C "$gdb_only_installdir" -J -f "$tarball.t" --owner 0 --group 0 --mode=a+u,og-w .
          mv "$tarball.t" "$tarball"
          chmod 444 "$tarball"
        else
          echo "Error: Directory '$gdb_only_installdir' does not exist."
        fi
      fi
    fi
    ;;

  check)
    if [ $flag_enable_newlib_nano -eq 1 ]; then
      if [ $flag_enable_newlib_nano_check -eq 1 ]; then
        check_targets="$check_targets $check_nano_targets"
      fi
    fi
    push_stages ${check_targets}
    ;;

  check-binutils | check-ld | check-gas)
    timelimit=120
    ( ulimit -v $memlimit &&
      RUNTESTFLAGS="$RUNTESTFLAGS" \
      DEJAGNU_TIMEOUT=$timelimit toolchain_prefix="$installdir$prefix" \
      make -C "$objdir/binutils" $parallel -k "$stage" \
      CC_FOR_TARGET="$installdir$prefix/bin/$target-gcc") || true
    # Capture the results
    mkdir -p "$resultdir/vanilla"
    name=`echo "$stage" | sed "s/check-target-//" | sed "s/check-//"`
    for f in `find "$objdir" -type f -name "$name.log" -o -type f -name "$name.sum" -o -type f -name "$name.xml"`
    do
      cp "$f" "$resultdir/vanilla"
    done
    ;;

  check-target-newlib)
    check_in_newlib "$objdir/newlib" "$installdir/$prefix" "$stage" "$resultdir/vanilla"
    ;;

  check-target-newlib-nano)
    base_stage=$(echo "$stage" | sed 's/-nano$//')
    check_in_newlib "$objdir/newlib-nano" "$nano_installdir/$nano_prefix" "$base_stage" "$resultdir/nano"
    ;;

  check-gdb)
    # We can only test aarch64 gdb against the qemu board at present.
    # If no --target-board was specified arrange to set the default.
    if [ $flag_enable_gdb -eq 1 ] ; then

      case $target in
      aarch64-*-elf | aarch64*-elf)
        default_target_board="aarch64-elf-qemu"
        # LOOK! We don't run this anymore! It is too
        # unreliable and needs properly debugging.
        flag_check_gdb=0
        ;;

      aarch64_be-*-elf | aarch64_be*-elf)
        default_target_board="aarch64-elf-qemu"
        # LOOK! We don't run this anymore! It is too
        # unreliable and needs properly debugging.
        flag_check_gdb=0
        ;;

      arm*-*-eabi | arm*-eabi)
        default_target_board="arm-eabi-qemu-ar-class"

        # LOOK! We don't run this for arm-none-eabi anymore! It is too
        # unreliable and needs properly debugging.
        flag_check_gdb=0
        ;;
      esac

      if [ $flag_check_gdb -eq 1 ]; then
        ( ulimit -v $memlimit &&
          RUNTESTFLAGS="${default_target_board:+--target_board=$default_target_board} $RUNTESTFLAGS" \
          toolchain_prefix="$installdir$prefix" make -C "$objdir/gdb" $parallel -k "$stage") || true

        # Capture the results
        mkdir -p "$resultdir/vanilla"
        name=`echo "$stage" | sed "s/check-target-//" | sed "s/check-//"`
        for f in `find "$objdir/gdb" -type f -name "$name.log" -o -type f -name "$name.sum"`
        do
          cp "$f" "$resultdir/vanilla"
        done
      fi
    fi
    ;;

  check-gcc | check-g++ | check-fortran)
    name=`echo "$stage" | sed "s/check-target-//;s/fortran/gfortran/;s/check-//"`
    check_in_gcc "$name" "$objdir/gcc2/gcc" "$stage" "$resultdir/vanilla"
    ;;

  check-gcc-nano | check-g++-nano | check-fortran-nano)
    stage=$(echo "$stage" | sed 's/-nano$//')
    name=`echo "$stage" | sed "s/check-target-//;s/fortran/gfortran/;s/check-//"`
    check_in_gcc "$name" "$objdir/gcc2-nano/gcc" "$stage" "$resultdir/nano"
    ;;

  check-target-libstdc++-v3)
    check_in_gcc "libstdc++" "$objdir/gcc2" "$stage" "$resultdir/vanilla"
    ;;

  check-target-libstdc++-v3-nano)
    stage=$(echo "$stage" | sed 's/-nano$//')
    check_in_gcc "libstdc++" "$objdir/gcc2-nano" "$stage" "$resultdir/nano"
    ;;

  check-*)
    printf "warning: skipping $stage\n" >&2
    ;;

  stop)
    echo "  $target completed as requested"
    exit 0
    ;;

  *)
    echo "error: unknown stage: $stage"
    rm -f ,stage
    exit 1
    ;;
  esac
done
