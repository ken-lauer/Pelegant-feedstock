#!/usr/bin/env bash

set -ex -o pipefail

mkdir oag
mkdir epics

# Archives have overlapping directories. Additionally, conda will remove empty
# top-level directories which is not what we want.  So here we combine
# all of the extracted contents into their correct spots:
cp -a src/elegant/* oag
cp -a src/oag-apps/* oag
cp -a src/sdds/* epics/
cp -a src/epics-base/* epics/
cp -a src/epics-extensions/* epics/

rm -rf src/

if ! command -v mpicc; then
  echo "* mpicc not found? Was the environment built correctly?"
  exit 1
fi

echo "* Work root:    $SRC_DIR"
echo "* Conda prefix: $PREFIX"

echo "* Patching EPICS_BASE path for oag"
# shellcheck disable=SC2016
sed -i -e 's@^#\s*EPICS_BASE.*@EPICS_BASE=$(TOP)/../../epics/base@' "${SRC_DIR}/oag/apps/configure/RELEASE"

if [[ $(uname -m) == 'arm64' ]]; then
  echo "* Patching libpng config.h for ARM support"
  # Ensure ARM support is configured or the build will fail
  if grep 'undef PNG_ARM_NEON' epics/extensions/src/SDDS/png/config.h; then
    patch --forward -p1 < "${RECIPE_DIR}/png_config.h.patch"
  fi
  echo "* Patching mpicc and mpicxx for recent macOS Xcode compatibility"
  # See https://github.com/orgs/Homebrew/discussions/4797
  # This is also a reason why we want our own conda build env...
  sed -i '' \
    's/final_ldflags="\(.*\),-commons,use_dylibs"/final_ldflags="\1"/' \
    "$(readlink -f "$(which mpicc)")" \
    "$(readlink -f "$(which mpicxx)")"
else
  echo "* ARM not detected; skipping libpng patch"
fi

if [ -n "$SDKROOT" ]; then
  echo "SDKROOT was $SDKROOT but we're unsetting it. MacOS builds will fail otherwise."
  unset SDKROOT
fi

echo "* Setting up EPICS build system"
pushd "${SRC_DIR}/epics/base" || exit
make
popd

EPICS_HOST_ARCH=$("${SRC_DIR}"/epics/base/startup/EpicsHostArch)
echo "* EPICS_HOST_ARCH=${EPICS_HOST_ARCH}"

MAKE_ALL_ARGS=(
  "HDF_LIB_LOCATION=$PREFIX/lib" 
  # Now, we don't want to override CFLAGS globally as we'll run into issues.
  # The best I can tell is we can add our CFLAGS/LDFLAGS on a per-target
  # basis for some of the troublesome Makefile targets, like hdf2sdds
  # which looks for a couple fixed places (macports) for libraries like hdf5.
  "editstring_CFLAGS=-I$PREFIX/include"
  "editstring_LDFLAGS=-L$PREFIX/lib"
  "hdf2sdds_CFLAGS=-I$PREFIX/include"
  "hdf2sdds_LDFLAGS=-L$PREFIX/lib"
  "sdds2hdf_CFLAGS=-I$PREFIX/include"
  "sdds2hdf_LDFLAGS=-L$PREFIX/lib"
  "replaceText_CFLAGS=-I$PREFIX/include"
  "replaceText_LDFLAGS=-L$PREFIX/lib"
  "isFileLocked_CFLAGS=-I$PREFIX/include"
  "isFileLocked_LDFLAGS=-L$PREFIX/lib"
)

echo "* Make args:     ${MAKE_ALL_ARGS[@]}"
MPI_ARGS=(
  "MPI=1" 
  "MPICH_CC=gcc" 
  "MPICH_CXX=g++" 
  "MPI_PATH=$(dirname $(which mpicc))/"
  "EPICS_HOST_ARCH=$EPICS_HOST_ARCH"
  "COMMANDLINE_LIBRARY="
  "LINKER_USE_RPATH=NO"
  # "SHARED_LIBRARIES=NO"
)

echo "* Make MPI args: ${MAKE_MPI_ARGS[@]}"
echo "* Patching SDDS utils"
# APS may have this patched locally; these were changed long before 1.12.1
# which they reportedly use:
SDDS_UTILS="${SRC_DIR}/epics/extensions/src/SDDS/utils"
sed -i -e 's/H5Dopen(/H5Dopen1(/g' "$SDDS_UTILS/"*.c
sed -i -e 's/H5Aiterate(/H5Aiterate1(/g'  "$SDDS_UTILS/"*.c
sed -i -e 's/H5Acreate(/H5Acreate1(/g' "$SDDS_UTILS/"*.c
sed -i -e 's/H5Gcreate(/H5Gcreate1(/g' "$SDDS_UTILS/"*.c
sed -i -e 's/H5Dcreate(/H5Dcreate1(/g' "$SDDS_UTILS/"*.c

# Sorry, we're not going to build the motif driver.
echo -e "all:\ninstall:\nclean:\n" > "${SRC_DIR}/epics/extensions/src/SDDS/SDDSaps/sddsplots/motifDriver/Makefile"

echo "* Building SDDS - LIBONLY"
pushd "${SRC_DIR}/epics/extensions/src/SDDS" || exit
# First, build some non-MPI things (otherwise we don't get editstring, nlpp)
make "${MAKE_ALL_ARGS[@]}" LIBONLY=1

# Clean out the artifacts from the non-MPI build and then build with MPI:
echo "* Cleaning non-MPI build"
make clean
echo "* Building SDDS with MPI"
make "${MPI_ARGS[@]}" "${MAKE_ALL_ARGS[@]}"
popd

echo "* Building SDDS tools"
pushd "${SRC_DIR}/oag/apps/src/utils/tools" || exit
make "${MPI_ARGS[@]}"
popd

sed -i -e 's/^epicsShareFuncFDLIBM //g' "${SRC_DIR}/epics/extensions/src/SDDS/include"/*.h

# Build additional SDDS portions not already done:
for sdds_part in \
  pgapack    \
  cmatlib    \
; do
  echo "* Building SDDS $sdds_part"
  pushd "${SRC_DIR}/epics/extensions/src/SDDS/${sdds_part}" || exit
  make "${MPI_ARGS[@]}"
  popd
done

echo "* Building SDDS python"
pushd "${SRC_DIR}/epics/extensions/src/SDDS/python" || exit
make "${MPI_ARGS[@]}" PYTHON=310 PYTHON3=1
popd

if command -v nlpp; then
  echo "* nlpp already in PATH: $(which nlpp)"
else
  echo "* Adding extension bin directory to PATH for nlpp"
  export PATH="${SRC_DIR}/epics/extensions/bin/${EPICS_HOST_ARCH}:$PATH" 
fi

echo "* Building Pelegant"
pushd "${SRC_DIR}/oag/apps/src/elegant/" || exit
make Pelegant \
  "${MPI_ARGS[@]}" \
  GSL=1 \
  gsl_DIR="$PREFIX/lib" \
  gslcblas_DIR="$PREFIX/lib" \
  USER_MPI_FLAGS="-DUSE_MPI=1 -DSDDS_MPI_IO=1 -I$PREFIX/include"
popd

echo "* Building elegant tools"
pushd "${SRC_DIR}/oag/apps/src/elegant/elegantTools" || exit
make \
  GSL=1 \
  gsl_DIR="$PREFIX/lib" \
  gslcblas_DIR="$PREFIX/lib" \
  USER_MPI_FLAGS="-DUSE_MPI=1 -DSDDS_MPI_IO=1 -I$PREFIX/include"
popd

PELEGANT_BINARY="${SRC_DIR}/oag/apps/bin/${EPICS_HOST_ARCH}/Pelegant"
echo "* Done"

echo "* Adjusting rpath for $PREFIX/lib"
for binary in "${SRC_DIR}/oag/apps/bin/${EPICS_HOST_ARCH}/"* "${SRC_DIR}/epics/extensions/bin/${EPICS_HOST_ARCH}/"*; do
  chmod +w "$binary"
  "${INSTALL_NAME_TOOL}" -add_rpath "$PREFIX/lib" "$binary"
done

echo "* Trying out the Pelegant binary..."
ls -la "${PELEGANT_BINARY}"
"${PELEGANT_BINARY}"

echo "* Installing binaries to $PREFIX"
cp "${SRC_DIR}/oag/apps/bin/${EPICS_HOST_ARCH}/"* "${PREFIX}/bin"
cp "${SRC_DIR}/epics/extensions/bin/${EPICS_HOST_ARCH}/"* "${PREFIX}/bin"
