pkg_name=binutils
pkg_derivation=chef
pkg_version=2.25.1
pkg_maintainer="The Bldr Maintainers <bldr@chef.io>"
pkg_license=('gpl')
pkg_source=http://ftp.gnu.org/gnu/$pkg_name/${pkg_name}-${pkg_version}.tar.bz2
pkg_shasum=b5b14added7d78a8d1ca70b5cb75fef57ce2197264f4f5835326b0df22ac9f22
pkg_deps=(chef/glibc chef/zlib)
pkg_binary_path=(bin)
pkg_include_dirs=(include)
pkg_lib_dirs=(lib)
pkg_gpg_key=3853DA6B

do_begin() {
  # verify that PTYs are working properly
  local actual
  local expected='spawn ls'
  local cmd="expect -c 'spawn ls'"
  if actual=$(expect -c "spawn ls" | sed 's/\r$//'); then
    if [[ $expected != $actual ]]; then
      exit_with "Expected out from '$cmd' was: '$expected', actual: '$actual'" 1
    fi
  else
    exit_with "PTYs may not be working properly, aborting" 1
  fi
  return 0
}

do_prepare() {
  find . -iname "ltmain.sh" | while read file; do
    build_line "Fixing libtool script $file"
    sed -i -e 's^eval sys_lib_.*search_path=.*^^' "$file"
  done

  # TODO: We need a more clever way to calculate/determine the path to ld-*.so
  dynamic_linker="$(pkg_path_for glibc)/lib/ld-2.22.so"

  LDFLAGS="$LDFLAGS -Wl,-rpath=${LD_RUN_PATH},--enable-new-dtags"
  LDFLAGS="$LDFLAGS -Wl,--dynamic-linker=$dynamic_linker"
  export LDFLAGS
  build_line "Updating LDFLAGS=$LDFLAGS"

  # Don't depend on dynamically linked libgcc, as we don't want it denpending
  # on our /tools install.
  export CFLAGS="$CFLAGS -static-libgcc"
  build_line "Updating CFLAGS=$CFLAGS"

  # Make `--enable-new-dtags` the default so that the linker sets `RUNPATH`
  # instead of `RPATH` in ELF binaries. This is important as `RPATH` is
  # overridden if `LD_LIBRARY_PATH` is set at runtime.
  #
  # Thanks to: https://github.com/NixOS/nixpkgs/blob/2524504/pkgs/development/tools/misc/binutils/new-dtags.patch
  # Thanks to: https://build.opensuse.org/package/view_file?file=ld-dtags.diff&package=binutils&project=devel%3Agcc&srcmd5=011dbdef56800d1cd2fa8c585b3dd7db
  patch -p1 < $PLAN_CONTEXT/new-dtags.patch

  # Since binutils 2.22, DT_NEEDED flags aren't copied for dynamic outputs.
  # That requires upstream changes for things to work. So we can patch it to
  # get the old behaviour fo now.
  #
  # Thanks to: https://github.com/NixOS/nixpkgs/blob/d9f4b0a/pkgs/development/tools/misc/binutils/dtneeded.patch
  patch -p1 < $PLAN_CONTEXT/dt-needed-true.patch

  # # Make binutils output deterministic by default.
  #
  # Thanks to: https://github.com/NixOS/nixpkgs/blob/0889bbe/pkgs/development/tools/misc/binutils/deterministic.patch
  patch -p1 < $PLAN_CONTEXT/more-deterministic-output.patch

  cat $PLAN_CONTEXT/custom-libs.patch \
    | sed -e "s,@dynamic_linker@,$dynamic_linker,g" \
      -e "s,@glibc_lib@,$(pkg_path_for chef/glibc)/lib,g" \
      -e "s,@zlib_lib@,$(pkg_path_for chef/zlib)/lib,g" \
    | patch -p1

  # We don't want to search for libraries in system directories such as `/lib`,
  # `/usr/local/lib`, etc.
  echo 'NATIVE_LIB_DIRS=' >> ld/configure.tgt

  # Use symlinks instead of hard links to save space (otherwise `strip(1)`
  # needs to process each hard link seperately)
  for f in binutils/Makefile.in gas/Makefile.in ld/Makefile.in gold/Makefile.in; do
    sed -i "$f" -e 's|ln |ln -s |'
  done
}

do_build() {
  rm -rf ../${pkg_name}-build
  mkdir ../${pkg_name}-build
  pushd ../${pkg_name}-build > /dev/null
    ../$pkg_dirname/configure \
      --prefix=$pkg_prefix \
      --enable-shared \
      --enable-deterministic-archives \
      --enable-threads \
      --disable-werror

    # Check the environment to make sure all the necessary tools are available
    make configure-host

    make tooldir=$pkg_prefix

    # This testsuite is pretty sensitive to its environment, especially when
    # libraries and headers are being flown in from non-standard locations.
    if [ -n "${DO_CHECK}" ]; then
      original_LD_RUN_PATH="$LD_RUN_PATH"
      export LD_LIBRARY_PATH="$LD_RUN_PATH"
      unset LD_RUN_PATH
      make check LDFLAGS=""
      unset LD_LIBRARY_PATH
      export LD_RUN_PATH="$original_LD_RUN_PATH"
    fi
  popd > /dev/null
}

do_install() {
  pushd ../${pkg_name}-build > /dev/null
    make prefix=$pkg_prefix tooldir=$pkg_prefix install

    # Remove unneeded files
    rm -fv ${pkg_path}/share/man/man1/{dlltool,nlmconv,windres,windmc}*

    # No shared linking to these files outside binutils
    rm -fv ${pkg_path}/lib/lib{bfd,opcodes}.so
  popd > /dev/null
}