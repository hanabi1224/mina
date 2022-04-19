#!/bin/bash
make libp2p_helper
export MINA_LIBP2P_HELPER_PATH=$PWD/src/app/libp2p_helper/result/bin/libp2p_helper
export DUNE_PROFILE=mainnet
dune build src/app/bin_prot_of_precomputed/bin_prot_of_precomputed.exe --profile=$DUNE_PROFILE
dune build src/app/cli/src/mina.exe --profile=$DUNE_PROFILE
./_build/default/src/app/cli/src/mina.exe daemon \
  --config-file genesis_ledgers/mainnet.json \
  --peer-list-url https://storage.googleapis.com/mina-seed-lists/mainnet_seeds.txt
