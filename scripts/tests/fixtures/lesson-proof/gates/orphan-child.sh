#!/usr/bin/env bash
# A grandchild calls setsid (node detached) and ignores the gate's death.
# Killing this shell is not enough. The checker has to kill the tree.
trap '' TERM
set +e
LESSON_PROOF_ENFORCE=1

if [[ "$LESSON_PROOF_ENFORCE" == "1" ]]; then
  node -e 'const {spawn}=require("node:child_process"); const c=spawn("sleep",["45"],{detached:true,stdio:"ignore",argv0:"lesson-proof-orphan-sentinel"}); c.unref(); setInterval(()=>{},1000);' &
  wait
fi
exit 0
