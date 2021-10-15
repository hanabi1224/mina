package main

import (
	"codanet"
	"context"
	ipc "libp2p_ipc"
	"time"

	"capnproto.org/go/capnp/v3"
	"github.com/ipfs/go-bitswap"
	blocks "github.com/ipfs/go-block-format"
	"github.com/ipfs/go-cid"
	blockstore "github.com/ipfs/go-ipfs-blockstore"
	exchange "github.com/ipfs/go-ipfs-exchange-interface"
	logging "github.com/ipfs/go-log"
)

var bitswapLogger = logging.Logger("mina.helper.bitswap")

type bitswapDeleteCmd struct {
	rootIds []BitswapBlockLink
}

type bitswapAddCmd struct {
	data []byte
}

type bitswapDownloadCmd struct {
	rootIds []BitswapBlockLink
}

type root BitswapBlockLink

type BitswapCtx struct {
	downloadCmds        chan bitswapDownloadCmd
	addCmds             chan bitswapAddCmd
	deleteCmds          chan bitswapDeleteCmd
	engine              *bitswap.Bitswap
	storage             codanet.BitswapStorage
	ctx                 context.Context
	childDownloadParams map[cid.Cid]*ChildDownloadParams
	blockSink           chan blocks.Block
	rootDownloadStates  map[root]*RootDownloadState
	deadlineChan        chan root
	outMsgChan          chan<- *capnp.Message
	rootDownloadTimeout time.Duration
	maxBlockSize        int
	maxBlockTreeDepth   int
}

type ChildDownloadParams struct {
	root  root
	depth int
}

type RootDownloadState struct {
	notVisited              *cid.Set
	allDescedants           *cid.Set
	session                 exchange.Fetcher
	ctx                     context.Context
	cancelF                 context.CancelFunc
	treeDepth               int // either 0 or depth of block tree for the root
	processedNonMaxSizeNode bool
}

func NewBitswapCtx(ctx context.Context, outMsgChan chan<- *capnp.Message) *BitswapCtx {
	return &BitswapCtx{
		downloadCmds:        make(chan bitswapDownloadCmd, 100),
		addCmds:             make(chan bitswapAddCmd, 100),
		deleteCmds:          make(chan bitswapDeleteCmd, 100),
		ctx:                 ctx,
		rootDownloadStates:  make(map[root]*RootDownloadState),
		childDownloadParams: make(map[cid.Cid]*ChildDownloadParams),
		blockSink:           make(chan blocks.Block, 100),
		deadlineChan:        make(chan root, 100),
		outMsgChan:          outMsgChan,
		rootDownloadTimeout: time.Minute * 10,
		maxBlockTreeDepth:   2,
		maxBlockSize:        1 << 18,
	}
}

func announceNewRootBlock(engine *bitswap.Bitswap, statusStorage codanet.BitswapStorage, bs map[BitswapBlockLink][]byte, root BitswapBlockLink) error {
	err := statusStorage.SetStatus(root, codanet.Partial)
	if err != nil {
		return err
	}

	for h, b := range bs {
		id := codanet.BlockHashToCid(h)
		bitswapLogger.Debugf("Publishing block %s (%d bytes)", id, len(b))
		block, _ := blocks.NewBlockWithCid(b, id)
		err = engine.HasBlock(block)
		if err != nil {
			return err
		}
	}
	return statusStorage.SetStatus(root, codanet.Full)
}

func (bs *BitswapCtx) deleteRoot(root BitswapBlockLink) error {
	err := bs.storage.SetStatus(root, codanet.Deleting)
	if err != nil {
		return err
	}
	bs.freeRoot(root)
	allDescedants := []BitswapBlockLink{root}
	for i := 0; i < len(allDescedants); i++ {
		block := allDescedants[i]
		err := bs.storage.ViewBlock(block, func(b []byte) error {
			links, _, err := ReadBitswapBlock(b)
			if err == nil {
				for _, l := range links {
					var l2 BitswapBlockLink
					copy(l2[:], l[:])
					allDescedants = append(allDescedants, l2)
				}
			}
			return err
		})
		if err != nil && err != blockstore.ErrNotFound {
			return err
		}
	}
	return bs.storage.DeleteBlocks(allDescedants)
}

func asyncDownloadBlocks(ctx context.Context, session exchange.Fetcher, cids []cid.Cid, sink chan<- blocks.Block) error {
	ch, err := session.GetBlocks(ctx, cids)
	if err != nil {
		return err
	}
	go func() {
		for v := range ch {
			// bitswapLogger.Debugf("asyncDownloadBlocks: received block %s (%d bytes)", v.Cid(), len(v.RawData()))
			sink <- v
		}
	}()
	return nil
}

func (bs *BitswapCtx) freeRoot(root BitswapBlockLink) {
	state, has := bs.rootDownloadStates[root]
	if !has {
		return
	}
	state.allDescedants.ForEach(func(c cid.Cid) error {
		delete(bs.childDownloadParams, c)
		return nil
	})
	delete(bs.rootDownloadStates, root)
	state.cancelF()
}

func (bs *BitswapCtx) sendResourceUpdate(type_ ipc.ResourceUpdateType, roots ...BitswapBlockLink) {
	// Non-blocking upcall sending
	select {
	case bs.outMsgChan <- mkResourceUpdatedUpcall(type_, roots):
	default:
		for _, root := range roots {
			bitswapLogger.Errorf("Failed to send resource update of type %d"+
				" for %s (message queue is full)",
				type_, codanet.BlockHashToCid(root))
		}
	}
}

func (bs *BitswapCtx) kickStartRootDownload(root BitswapBlockLink) {
	rootCid := codanet.BlockHashToCid(root)
	_, has := bs.childDownloadParams[rootCid]
	if has {
		bitswapLogger.Debugf("Skipping download request for %s (downloading already in progress)", codanet.BlockHashToCid(root))
		return // downloading already in progress
	}
	err := bs.storage.SetStatus(root, codanet.Partial)
	if err != nil {
		bitswapLogger.Debugf("Skipping download request for %s due to status: %w", codanet.BlockHashToCid(root), err)
		status, err := bs.storage.GetStatus(root)
		if err == nil && status == codanet.Full {
			bs.sendResourceUpdate(ipc.ResourceUpdateType_added, root)
		}
		return
	}
	s1 := cid.NewSet()
	s2 := cid.NewSet()
	s1.Add(rootCid)
	s2.Add(rootCid)
	ctx, cancelF := context.WithTimeout(bs.ctx, bs.rootDownloadTimeout)
	session := bs.engine.NewSession(ctx)
	bs.childDownloadParams[rootCid] = &ChildDownloadParams{
		root:  root,
		depth: 1,
	}
	bs.rootDownloadStates[root] = &RootDownloadState{
		notVisited:    s1,
		allDescedants: s2,
		ctx:           ctx,
		session:       session,
		cancelF:       cancelF,
	}
	var rootBlock []byte
	err = bs.storage.ViewBlock(root, func(b []byte) error {
		rootBlock := make([]byte, len(b))
		copy(rootBlock, b)
		return nil
	})
	hasRootBlock := err == nil
	if err == blockstore.ErrNotFound {
		err = asyncDownloadBlocks(ctx, session, []cid.Cid{rootCid}, bs.blockSink)
		bitswapLogger.Debugf("Requested download of %s", codanet.BlockHashToCid(root))
	}
	if err == nil {
		go func() {
			<-time.After(bs.rootDownloadTimeout)
			bs.deadlineChan <- root
		}()
	} else {
		bitswapLogger.Errorf("Error initializing block download: %w", err)
		bs.freeRoot(root)
	}
	if hasRootBlock {
		b, _ := blocks.NewBlockWithCid(rootBlock, rootCid)
		bs.processDownloadedBlock(b)
	}
}

func (bs *BitswapCtx) processDownloadedBlock(block blocks.Block) {
	id := block.Cid()
	params, foundRoot := bs.childDownloadParams[id]
	if !foundRoot {
		bitswapLogger.Warnf("Didn't find root for block: %s", id)
		return
	}
	root := params.root
	bitswapLogger.Debugf("Received block %s of root %s", block.Cid(), codanet.BlockHashToCid(root))
	rootState := bs.rootDownloadStates[root]
	if !rootState.notVisited.Has(id) {
		bitswapLogger.Warnf("Block %s of root %s visited twice", id, codanet.BlockHashToCid(root))
		return
	}
	reportMalformed := func(err string) {
		bitswapLogger.Warnf("Block %s of root %s is malformed: %s", id, codanet.BlockHashToCid(root), err)
		bs.freeRoot(root)
		bs.sendResourceUpdate(ipc.ResourceUpdateType_broken, root)
	}
	if bs.maxBlockTreeDepth < params.depth {
		reportMalformed("Malformed block tree: too deep a node")
		return
	}
	if rootState.treeDepth != 0 && rootState.treeDepth < params.depth {
		reportMalformed("Malformed block tree: non-balanced")
		return
	}
	if rootState.treeDepth != 0 && rootState.treeDepth > params.depth && len(block.RawData()) < bs.maxBlockSize {
		reportMalformed("Malformed block tree: non-max size of middle node")
		return
	}
	if len(block.RawData()) < bs.maxBlockSize {
		if rootState.processedNonMaxSizeNode {
			reportMalformed("Malformed block tree: second non-max size node")
			return
		}
		rootState.processedNonMaxSizeNode = true
	}
	rootState.notVisited.Remove(id)
	links, _, err := ReadBitswapBlock(block.RawData())
	if err != nil {
		bitswapLogger.Errorf("Error reading block: %v", block.RawData())
		reportMalformed(err.Error())
		return
	}
	if len(block.RawData()) < bs.maxBlockSize && len(links) > 0 {
		reportMalformed("Malformed block tree: nom-max size of non-leaf node")
		return
	}
	maxLink := LinksPerBlock(bs.maxBlockSize)
	if rootState.treeDepth == 0 && len(links) < maxLink {
		if len(links) == 0 {
			rootState.treeDepth = params.depth
		} else {
			rootState.treeDepth = params.depth + 1
		}
	}
	if rootState.treeDepth == params.depth && len(links) > 0 {
		reportMalformed("Malformed block tree: child of a parent with non-max" +
			" amount of links must have no links itself")
		return
	}
	blocksToProcess := make([]blocks.Block, 0)
	toDownload := make([]cid.Cid, 0, len(links))
	for _, link := range links {
		childId := codanet.BlockHashToCid(link)
		_, has := bs.childDownloadParams[childId]
		if has {
			reportMalformed("Not a tree: DAG supplied")
			return
		}
		bs.childDownloadParams[childId] = &ChildDownloadParams{
			root:  root,
			depth: params.depth + 1,
		}
		rootState.notVisited.Add(childId)
		rootState.allDescedants.Add(childId)
		var blockBytes []byte
		err = bs.storage.ViewBlock(link, func(b []byte) error {
			blockBytes = make([]byte, len(b))
			copy(blockBytes, b)
			return nil
		})
		if err == nil {
			b, _ := blocks.NewBlockWithCid(blockBytes, childId)
			blocksToProcess = append(blocksToProcess, b)
		} else {
			if err != blockstore.ErrNotFound {
				// we still schedule blocks for downloading
				// this case should rarely happen in practice
				bitswapLogger.Warnf("Failed to fetch block %s of root %s from storage: %w", childId, root, err)
			}
			toDownload = append(toDownload, childId)
		}
	}
	if len(toDownload) > 0 {
		asyncDownloadBlocks(rootState.ctx, rootState.session, toDownload, bs.blockSink)
	}
	if rootState.notVisited.Len() == 0 {
		// clean-up
		err := bs.storage.SetStatus(root, codanet.Full)
		if err != nil {
			bitswapLogger.Warnf("Failed to update status of fully downloaded root %s: %s", root, err)
		}
		bs.freeRoot(root)
		bs.sendResourceUpdate(ipc.ResourceUpdateType_added, root)
	}
	for _, b := range blocksToProcess {
		bs.processDownloadedBlock(b)
	}
}

// BitswapLoop: Bitswap processing loop
//  Do not launch more than one instance of it
func (bs *BitswapCtx) Loop() {
	engine := bs.engine
	storage := bs.storage
	configuredCheck := func() {
		if engine == nil || storage == nil {
			panic("BitswapLoop: context not configured")
		}
	}
	for {
		// TODO condition to end the loop?
		select {
		case <-bs.ctx.Done():
			return
		case root := <-bs.deadlineChan:
			configuredCheck()
			bs.freeRoot(root)
		case cmd := <-bs.addCmds:
			configuredCheck()
			blocks, root := SplitDataToBitswapBlocks(bs.maxBlockSize, cmd.data)
			err := announceNewRootBlock(engine, storage, blocks, root)
			if err == nil {
				bs.sendResourceUpdate(ipc.ResourceUpdateType_added, root)
			} else {
				bitswapLogger.Errorf("Failed to announce root cid %s (%w)", codanet.BlockHashToCid(root), err)
			}
		case cmd := <-bs.deleteCmds:
			configuredCheck()
			success := []BitswapBlockLink{}
			for _, root := range cmd.rootIds {
				err := bs.deleteRoot(root)
				if err == nil {
					err = storage.DeleteStatus(root)
				}
				if err == nil {
					success = append(success, root)
				} else {
					bitswapLogger.Errorf("Error processing delete request for %s: %w", codanet.BlockHashToCid(root), err)
				}
			}
			bs.sendResourceUpdate(ipc.ResourceUpdateType_removed, success...)
		case cmd := <-bs.downloadCmds:
			configuredCheck()
			// We put all ids to map to avoid
			// unneccessary querying in case of id duplicates
			m := make(map[BitswapBlockLink]bool)
			for _, root := range cmd.rootIds {
				m[root] = true
			}
			for root := range m {
				bs.kickStartRootDownload(root)
			}
		case block := <-bs.blockSink:
			configuredCheck()
			bs.processDownloadedBlock(block)
		}
	}
}
