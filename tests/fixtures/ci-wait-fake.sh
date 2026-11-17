#!/usr/bin/env bash
# Fake ci-wait.sh for shape tests (SWARM_MERGE_TEST_HOOKS=1 CI_WAIT_SCRIPT=...).
# FAKE_CI_WAIT_MODE: green (exit 0, names FAKE_CI_WAIT_HEAD) | other-head | red (exit 1).
echo "$*" >> "${FAKE_CI_WAIT_LOG:-/dev/null}"
case "${FAKE_CI_WAIT_MODE:-red}" in
  green)      echo "ci-wait: verified-head=${FAKE_CI_WAIT_HEAD:-aaa1111}"; exit 0 ;;
  other-head) echo "ci-wait: verified-head=ccc3333"; exit 0 ;;
  *)          echo "ci-wait: checks failing"; exit 1 ;;
esac
