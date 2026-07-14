#!/bin/bash
# Init foundry dans contracts/ (base-forge WSL — piège quoting B20 : toujours passer par un .sh)
set -e
cd "/mnt/c/Users/soufj/Desktop/Programme Créer/arc-treasury-agent/contracts"
~/.foundry/bin/base-forge init . --no-git --force
rm -f src/Counter.sol test/Counter.t.sol script/Counter.s.sol
echo "OK forge init"
