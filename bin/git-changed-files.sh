#!/bin/bash
git diff --name-only $GIT_PREVIOUS_COMMIT ${GIT_COMMIT:HEAD^}
