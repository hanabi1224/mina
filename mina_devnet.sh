#!/bin/bash
make libp2p_helper
export MINA_LIBP2P_HELPER_PATH=$PWD/src/app/libp2p_helper/result/bin/libp2p_helper
export DUNE_PROFILE=devnet
dune build src/app/cli/src/mina.exe --profile=$DUNE_PROFILE
./_build/default/src/app/cli/src/mina.exe daemon \
  --config-file genesis_ledgers/devnet.json \
  --seed \
  --demo-mode \
  --peer-list-url https://storage.googleapis.com/seed-lists/devnet_seeds.txt
