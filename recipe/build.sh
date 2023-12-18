#!/usr/bin/env bash

PELEGANT_VERSION="${PELEGANT_VERSION=2023.3.0}"
SDDS_VERSION="${SDDS_VERSION=5.5}"

[ -z "$PELEGANT_VERSION" ] && { echo "PELEGANT_VERSION unset"; exit 1; }
[ -z "$SDDS_VERSION" ] && { echo "SDDS_VERSION unset"; exit 1; }

WORK_ROOT=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ELEGANT_ROOT="${WORK_ROOT}/oag/apps/src/elegant/"

echo "* Attempt at a basic Pelegant build tool"

if ! command -v mpicc; then
  echo "* mpicc not found? Was the environment built correctly?"
  exit 1
fi

echo "* Version:      $PELEGANT_VERSION"
echo "* SDDS:         $SDDS_VERSION"
echo "* Work root:    $WORK_ROOT"
echo "* Elegant root: $ELEGANT_ROOT"
echo "* Conda prefix: $CONDA_PREFIX"

set -ex -o pipefail

echo "* Patching EPICS_BASE path for oag"
# shellcheck disable=SC2016
sed -i -e 's@^#\s*EPICS_BASE.*@EPICS_BASE=$(TOP)/../../epics/base@' "${WORK_ROOT}/oag/apps/configure/RELEASE"

if [[ $(uname -m) == 'arm64' ]]; then
  echo "* Patching libpng config.h for ARM support"
  # Ensure ARM support is configured or the build will fail
  if grep 'undef PNG_ARM_NEON' epics/extensions/src/SDDS/png/config.h; then
    patch --forward -p1 < "${WORK_ROOT}/patches/arm64/png_config.h"
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

if [[ $(uname -o) == 'Darwin' ]]; then
  export LD_RPATH="-rpath ${CONDA_PREFIX}/lib"
else
  export LD_RPATH="-Wl,-rpath-link,${CONDA_PREFIX}/lib"
fi
export CFLAGS="${CFLAGS} -I${CONDA_PREFIX}/include"
export LDFLAGS="${LDFLAGS} -L${CONDA_PREFIX}/lib ${LD_RPATH}"

echo "* Setting up EPICS build system"
pushd "${WORK_ROOT}/epics/base" || exit
make
popd

EPICS_HOST_ARCH=$("${WORK_ROOT}"/epics/base/startup/EpicsHostArch)
echo "* EPICS_HOST_ARCH=${EPICS_HOST_ARCH}"

MAKE_ALL_ARGS=(
  "HDF_LIB_LOCATION=$CONDA_PREFIX/lib" 
  # Now, we don't want to override CFLAGS globally as we'll run into issues.
  # The best I can tell is we can add our CFLAGS/LDFLAGS on a per-target
  # basis for some of the troublesome Makefile targets, like hdf2sdds
  # which looks for a couple fixed places (macports) for libraries like hdf5.
  # "CFLAGS=$CFLAGS" 
  # "LDFLAGS=$LDFLAGS" 
  "editstring_CFLAGS=-I$CONDA_PREFIX/include"
  "editstring_LDFLAGS=-L$CONDA_PREFIX/lib"
  "hdf2sdds_CFLAGS=-I$CONDA_PREFIX/include"
  "hdf2sdds_LDFLAGS=-L$CONDA_PREFIX/lib"
  "sdds2hdf_CFLAGS=-I$CONDA_PREFIX/include"
  "sdds2hdf_LDFLAGS=-L$CONDA_PREFIX/lib"
  "replaceText_CFLAGS=-I$CONDA_PREFIX/include"
  "replaceText_LDFLAGS=-L$CONDA_PREFIX/lib"
  "isFileLocked_CFLAGS=-I$CONDA_PREFIX/include"
  "isFileLocked_LDFLAGS=-L$CONDA_PREFIX/lib"
)

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

echo "* Make args:     ${MAKE_ALL_ARGS[@]}"
echo "* Make MPI args: ${MAKE_MPI_ARGS[@]}"

NUM_PROC=${NUM_PROC=8}

echo "* Building in parallel with: ${NUM_PROC} processes"

if [[ "$SKIP_SDDS" == "1" ]]; then
  echo "* Skipping SDDS lib and tools due to SKIP_SDDS environment variable setting"
else

  echo "* Patching SDDS utils"
  # APS may have this patched locally; these were changed long before 1.12.1
  # which they reportedly use:
  SDDS_UTILS="${WORK_ROOT}/epics/extensions/src/SDDS/utils"
  sed -i -e 's/H5Dopen(/H5Dopen1(/g' "$SDDS_UTILS/"*.c
  sed -i -e 's/H5Aiterate(/H5Aiterate1(/g'  "$SDDS_UTILS/"*.c
  sed -i -e 's/H5Acreate(/H5Acreate1(/g' "$SDDS_UTILS/"*.c
  sed -i -e 's/H5Gcreate(/H5Gcreate1(/g' "$SDDS_UTILS/"*.c
  sed -i -e 's/H5Dcreate(/H5Dcreate1(/g' "$SDDS_UTILS/"*.c

  # Sorry, we're not going to build the motif driver.
  echo -e "all:\ninstall:\nclean:\n" > "${WORK_ROOT}/epics/extensions/src/SDDS/SDDSaps/sddsplots/motifDriver/Makefile"

  echo "* Building SDDS - LIBONLY"
  pushd "${WORK_ROOT}/epics/extensions/src/SDDS" || exit
  # First, build some non-MPI things (otherwise we don't get editstring, nlpp)
  make "${MAKE_ALL_ARGS[@]}" LIBONLY=1

  # -j"${NUM_PROC}"
  # Clean out the artifacts from the non-MPI build and then build with MPI:
  echo "* Cleaning non-MPI build"
  make clean
  echo "* Building SDDS with MPI"
  make "${MPI_ARGS[@]}" "${MAKE_ALL_ARGS[@]}"
  popd

  echo "* Building SDDS tools"
  pushd "${WORK_ROOT}/oag/apps/src/utils/tools" || exit
  make "${MPI_ARGS[@]}"
  popd

fi

sed -i -e 's/^epicsShareFuncFDLIBM //g' "${WORK_ROOT}/epics/extensions/src/SDDS/include"/*.h

# We may not *need* to build these individually. However these are the bare
# minimum necessary for Pelegant. So let's go with it for now.
for sdds_part in \
  mdblib     \
  mdbmth     \
  mdbcommon  \
  namelist   \
  pgapack    \
  rpns/code  \
  matlib     \
  fftpack    \
  lzma       \
  meschach   \
  tiff       \
  SDDSaps    \
  zlib       \
  2d_interpolate \
  cmatlib    \
  fft2d      \
  png        \
  gd         \
  oagLib     \
  utils      \
  xlslib     \
; do
  echo "* Building SDDS $sdds_part"
  pushd "${WORK_ROOT}/epics/extensions/src/SDDS/${sdds_part}" || exit
  make "${MPI_ARGS[@]}"
  popd
done

echo "* Building SDDS python"
pushd "${WORK_ROOT}/epics/extensions/src/SDDS/python" || exit
make "${MPI_ARGS[@]}" PYTHON=310 PYTHON3=1
popd
# excluded:
#  OOSDDSlib - not in original makefile
#  SDDS3lib  - template linkage issue
#  daq       - missing ttf2_daq_reader
#  fortran   - not built in Makefile normally
#  fdlibm    - finite definition not portable
#  gnuplot   - not built normally
#  java      - java
if [ -f "${ELEGANT_ROOT}/Makefile.TMP" ]; then
  # Elegant does a... funny thing with its Makefiles instead of using different
  # targets for some reason?
  echo "* Previous (failed?) build; restoring elegant top-level Makefile"
  mv "${ELEGANT_ROOT}/Makefile.TMP" "${ELEGANT_ROOT}/Makefile"
fi

echo "* Building Pelegant"
pushd "${ELEGANT_ROOT}" || exit
if command -v nlpp; then
  echo "* nlpp already in PATH: $(which nlpp)"
else
  echo "* Adding extension bin directory to PATH for nlpp"
  export PATH="${WORK_ROOT}/epics/extensions/bin/${EPICS_HOST_ARCH}:$PATH" 
fi
make Pelegant \
  "${MPI_ARGS[@]}" \
  GSL=1 \
  gsl_DIR="$CONDA_PREFIX/lib" \
  gslcblas_DIR="$CONDA_PREFIX/lib"
popd

ELEGANT_BINARY="${WORK_ROOT}/oag/apps/bin/${EPICS_HOST_ARCH}/Pelegant"
echo "* Done"

ls -la "${ELEGANT_BINARY}"
"${ELEGANT_BINARY}"

cp "${WORK_ROOT}/oag/apps/bin/${EPICS_HOST_ARCH}/*" "${CONDA_PREFIX}/bin"
cp "${WORK_ROOT}/epics/extensions/bin/${EPICS_HOST_ARCH}/*" "${CONDA_PREFIX}/bin"
