#!/bin/bash
# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# `-e` enables the script to automatically fail when a command fails
# `-o pipefail` sets the exit code to the rightmost comment to exit with a non-zero
set -eo pipefail
# Enables `**` to include files nested inside sub-folders
shopt -s globstar


# `--only-changed` will only run tests on projects container changes from the master branch.
if [[ $* == *--only-diff* ]]; then
    ONLY_DIFF="true"
else
    ONLY_DIFF="false"
fi


check_if_changed(){
    # Ignore this test if there are no changes.
    cd "${KOKORO_ARTIFACTS_DIR}"/github/ai-platform-samples-1/"${CAIP_TEST_DIR}"
    DIFF=$(git diff master "${KOKORO_GITHUB_PULL_REQUEST_COMMIT}" "${PWD}")
    echo -e "git diff:\n ${DIFF}"
    if [[ -z ${DIFF} ]]; then
        echo -e "Test ignored; directory was not modified in pull request ${KOKORO_GITHUB_PULL_REQUEST_NUMBER}"
        exit 0
    fi
}


project_setup(){
    # Update to latest SDK for gcloud ai-platform command.
    local KEYFILE="${KOKORO_GFILE_DIR}/keyfile.json"
    gcloud components update --quiet
    export GOOGLE_APPLICATION_CREDENTIALS="${KEYFILE}"
    gcloud auth activate-service-account --key-file "${KEYFILE}"
    gcloud config list
}


create_virtualenv(){
    virtualenv -p $(which "${CAIP_PYTHON_VERSION}") "${KOKORO_ARTIFACTS_DIR}"/envs/"${CAIP_PYTHON_VERSION}"/venv
    source "${KOKORO_ARTIFACTS_DIR}"/envs/"${CAIP_PYTHON_VERSION}"/venv/bin/activate
}


download_files() {
    # Download files for testing.
    GCS_FOLDER="gs://cloud-samples-data/ml-engine/chicago_taxi"
    data_dir="${KOKORO_ARTIFACTS_DIR}"/data
    echo "------------------------------------------------------------"
    echo "- downloading files to $data_dir"
    echo "------------------------------------------------------------"
    gsutil cp ${GCS_FOLDER}/training/small/taxi_trips_train.csv "${data_dir}"/taxi_trips_train.csv
    gsutil cp ${GCS_FOLDER}/training/small/taxi_trips_eval.csv "${data_dir}"/taxi_trips_eval.csv
    gsutil cp ${GCS_FOLDER}/prediction/taxi_trips_prediction_dict.ndjson "${data_dir}"/taxi_trips_prediction_dict.ndjson

    # Define ENV for `train-local.sh` script
    export TAXI_TRAIN_SMALL="${data_dir}"/taxi_trips_train.csv
    export TAXI_EVAL_SMALL="${data_dir}"/taxi_trips_eval.csv
    export TAXI_PREDICTION_DICT_NDJSON="${data_dir}"/taxi_trips_prediction_dict.ndjson
}


run_flake8() {
    pip install -q flake8
    flake8 --max-line-length=80 . --statistics
    result=$?
    if [ ${result} -ne 0 ];then
      echo -e "\n Testing failed: flake8 returned a non-zero exit code. \n"
      exit 1
    else
      echo -e "\n flake8 run successfully in directory $(pwd).\n"
    fi
}

test_directory() {
  set +e
  # Use RTN to return a non-zero value if the test fails.
  RTN=0
  ROOT=$(pwd)
  # Download training and test data
  download_files
  for file in **/train-local.sh; do
      cd "$ROOT"
      # Navigate to the project folder.
      file=$(dirname "$file")
      cd "$file"
      # If $DIFF_ONLY is true, skip projects without changes.
      if [[ "$ONLY_DIFF" = "true" ]]; then
          git diff --quiet origin/master.. .
          CHANGED=$?
          if [[ "$CHANGED" -eq 0 ]]; then
            # echo -e "\n Skipping $file: no changes in folder.\n"
            continue
          fi
      fi
      cd "${KOKORO_ARTIFACTS_DIR}"/"${file%/*}"
      run_flake8
      echo "------------------------------------------------------------"
      echo "- testing $file"
      echo "------------------------------------------------------------"
      source scripts/train-local.sh
      EXIT=$?
      if [[ $EXIT -ne 0 ]]; then
        RTN=1
        echo -e "\n Testing failed: Nox returned a non-zero exit code. \n"
      else
        echo -e "\n Testing completed.\n"
      fi
  done
  cd "$ROOT"
  exit "$RTN"
}

main(){
    project_setup
    create_virtualenv
    # Run specific test.
    test_directory
}

main
