#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

set -eou pipefail

# Install required python dependencies for developing
# Dependencies are defined in .pyproject.toml
if [ -z "${PYTHON_EXECUTABLE:-}" ];
then
  if [[ -z ${CONDA_DEFAULT_ENV:-} ]] || [[ ${CONDA_DEFAULT_ENV:-} == "base" ]] || [[ ! -x "$(command -v python)" ]];
  then
    PYTHON_EXECUTABLE=python3
  else
    PYTHON_EXECUTABLE=python
  fi
fi
echo "Using python executable: $PYTHON_EXECUTABLE"

PYTHON_SYS_VERSION="$($PYTHON_EXECUTABLE -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")"
# Check python version. Expect at least 3.10.x
if ! $PYTHON_EXECUTABLE -c "
import sys
if sys.version_info < (3, 10):
    sys.exit(1)
";
then
  echo "Python version must be at least 3.10.x. Detected version: $PYTHON_SYS_VERSION"
  exit 1
fi

if [[ "$PYTHON_EXECUTABLE" == "python" ]];
then
  PIP_EXECUTABLE=pip
elif [[ "$PYTHON_EXECUTABLE" == "python3" ]];
then
  PIP_EXECUTABLE=pip3
else
  PIP_EXECUTABLE=pip${PYTHON_SYS_VERSION}
fi

echo "Using pip executable: $PIP_EXECUTABLE"

# Since torchchat often uses main-branch features of pytorch, only the nightly
# pip versions will have the required features. The PYTORCH_NIGHTLY_VERSION value should
# agree with the third-party/pytorch pinned submodule commit.
#
# NOTE: If a newly-fetched version of the executorch repo changes the value of
# PYTORCH_NIGHTLY_VERSION, you should re-run this script to install the necessary
# package versions.
PYTORCH_NIGHTLY_VERSION=dev20250327

# Nightly version for torchvision
VISION_NIGHTLY_VERSION=dev20250327

# Nightly version for torchtune
TUNE_NIGHTLY_VERSION=dev20250327

# The pip repository that hosts nightly torch packages. cpu by default.
# If cuda is available, based on presence of nvidia-smi, install the pytorch nightly
# with cuda for faster execution on cuda GPUs.
if [[ -x "$(command -v nvidia-smi)" ]];
then
  TORCH_NIGHTLY_URL="https://download.pytorch.org/whl/nightly/cu126"
elif [[ -x "$(command -v rocminfo)" ]];
then
  TORCH_NIGHTLY_URL="https://download.pytorch.org/whl/nightly/rocm6.2"
elif [[ -x "$(command -v xpu-smi)" ]];
then
  TORCH_NIGHTLY_URL="https://download.pytorch.org/whl/nightly/xpu"
else
  TORCH_NIGHTLY_URL="https://download.pytorch.org/whl/nightly/cpu"
fi

# pip packages needed by exir.
if [[ -x "$(command -v xpu-smi)" ]];
then
  REQUIREMENTS_TO_INSTALL=(
    torch=="2.8.0.${PYTORCH_NIGHTLY_VERSION}"
    torchvision=="0.22.0.${VISION_NIGHTLY_VERSION}"
    #torchtune=="0.7.0" # no 0.6.0 on xpu nightly
  )
else
  REQUIREMENTS_TO_INSTALL=(
    torch=="2.8.0.${PYTORCH_NIGHTLY_VERSION}"
    torchvision=="0.22.0.${VISION_NIGHTLY_VERSION}"
    torchtune=="0.7.0.${TUNE_NIGHTLY_VERSION}"
  )
fi

#
# First install requirements in install/requirements.txt. Older torch may be
# installed from the dependency of other models. It will be overridden by
# newer version of torch nightly installed later in this script.
#
(
  set -x
  $PIP_EXECUTABLE install -r install/requirements.txt --extra-index-url "${TORCH_NIGHTLY_URL}"
)

# Uninstall triton, as nightly will depend on pytorch-triton, which is one and the same
(
  set -x
  $PIP_EXECUTABLE uninstall -y triton
)

# Install the requirements. --extra-index-url tells pip to look for package
# versions on the provided URL if they aren't available on the default URL.
(
  set -x
  $PIP_EXECUTABLE install --extra-index-url "${TORCH_NIGHTLY_URL}" \
    "${REQUIREMENTS_TO_INSTALL[@]}"
)

# Temporatory instal torchtune nightly from cpu nightly link since no torchtune nightly for xpu now
# TODO: Change to install torchtune from xpu nightly link, once torchtune xpu nightly is ready
if [[ -x "$(command -v xpu-smi)" ]];
then
(
  set -x
  $PIP_EXECUTABLE install --extra-index-url  "https://download.pytorch.org/whl/nightly/cpu" \
    torchtune=="0.6.0.${TUNE_NIGHTLY_VERSION}"
)
fi

bash install/install_torchao.sh

if [[ -x "$(command -v nvidia-smi)" ]]; then
  (
    set -x
    $PYTHON_EXECUTABLE torchchat/utils/scripts/patch_triton.py
  )
fi
(
  set -x
  $PIP_EXECUTABLE install evaluate=="0.4.3" lm-eval=="0.4.7" psutil=="6.0.0"
)
